--!strict
-- Lost Cart GDD §"Spawn -> Reveal -> Collect": the single most important
-- feeling in the game. Owns the CartRevealed remote end-to-end --
-- compress -> shake -> burst -> cart launches upward -> name/rarity/NEW
-- display -> hands off to TrainController so the real model glides into
-- the visible train. Everything here is local-only cosmetic flourish (the
-- server has already committed the claim by the time this fires; nothing
-- in this Controller can affect who owns the cart or what it is -- see
-- LostCartData's Security note and CartSpawnService's own comment on why
-- the cover Instance itself stays alive in Workspace briefly after claim,
-- purely so this sequence has something to animate).
--
-- Every timing number here scales off CartData.RarityDisplay's
-- RevealDuration/BurstParticleCount per rarity -- Common resolves in a
-- quarter-second, Secret gets a real "mini jackpot" beat, but nothing ever
-- exceeds ~1.6s total and nothing blocks player movement or input at any
-- point (GDD: "never lock the player into ... several-second animation").

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CartData = require(ReplicatedStorage.Shared.Configs.CartData)
local CartVisuals = require(ReplicatedStorage.Shared.Modules.CartVisuals)
local CartTemplateLookup = require(ReplicatedStorage.Shared.Modules.CartTemplateLookup)
local SoundController = require(script.Parent.SoundController)

local LostCartRevealController = {}

local player = Players.LocalPlayer

type RevealPayload = {
	cover: Model?,
	cartId: string?,
	displayName: string,
	rarity: string,
	isNew: boolean,
	mutation: string?, -- Lost Cart GDD Phase 4, always nil today -- see MutationData
}

local trainController: any

-- Phase timing split, as fractions of RarityDisplay.RevealDuration --
-- compress+shake stays snappy at every tier (that's what makes Common feel
-- "almost instant"); the reveal-hang beat is where the extra rarity drama
-- actually lives.
local COMPRESS_FRACTION = 0.28
local SHAKE_FRACTION = 0.17
local LAUNCH_FRACTION = 0.30
-- remaining fraction is the name/rarity hang before handoff to the train

local function playCompress(part: BasePart, duration: number)
	local baseSize = part.Size
	local tween = TweenService:Create(
		part,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(baseSize.X * 1.15, baseSize.Y * 0.45, baseSize.Z * 1.15) }
	)
	tween:Play()
	return tween
end

local function playShake(part: BasePart, duration: number, magnitude: number)
	local baseCFrame = part.CFrame
	local steps = 4
	local stepTime = duration / steps
	task.spawn(function()
		for i = 1, steps do
			local offset = Vector3.new(
				(math.random() - 0.5) * magnitude,
				0,
				(math.random() - 0.5) * magnitude
			)
			TweenService:Create(part, TweenInfo.new(stepTime, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				CFrame = baseCFrame + offset,
			}):Play()
			task.wait(stepTime)
		end
		if part.Parent then
			part.CFrame = baseCFrame
		end
	end)
end

local function playBurst(position: Vector3, color: Color3, particleCount: number, parent: Instance)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = parent

	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 22
	light.Brightness = 6
	light.Parent = anchor
	TweenService:Create(light, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Brightness = 0 }):Play()

	local attachment = Instance.new("Attachment")
	attachment.Parent = anchor

	local burst = Instance.new("ParticleEmitter")
	burst.Color = ColorSequence.new(color)
	burst.Lifetime = NumberRange.new(0.35, 0.6)
	burst.Speed = NumberRange.new(10, 18)
	burst.SpreadAngle = Vector2.new(180, 180)
	burst.Size = NumberSequence.new(0.35)
	burst.Rate = 0
	burst.Parent = attachment
	burst:Emit(particleCount)

	Debris:AddItem(anchor, 1.5)
end

-- Floating "DisplayName / RARITY / (NEW!)" world-space presentation for the
-- reveal beat itself -- separate from the cover's own idle "[RARITY] / ?"
-- billboard, since by this point the cover is gone and the real cart is
-- what's on screen.
local function playRevealText(anchorPart: BasePart, displayName: string, rarity: string, isNew: boolean, color: Color3, hangTime: number)
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(220, isNew and 100 or 78)
	billboard.StudsOffset = Vector3.new(0, anchorPart.Size.Y * 0.5 + 3, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = anchorPart

	local nameLabel = Instance.new("TextLabel")
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.new(1, 0, 0.5, 0)
	nameLabel.Font = Enum.Font.GothamBlack
	nameLabel.TextScaled = true
	nameLabel.Text = displayName
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.TextStrokeTransparency = 0.1
	nameLabel.Parent = billboard

	local rarityLabel = Instance.new("TextLabel")
	rarityLabel.BackgroundTransparency = 1
	rarityLabel.Size = UDim2.new(1, 0, 0.35, 0)
	rarityLabel.Position = UDim2.new(0, 0, 0.5, 0)
	rarityLabel.Font = Enum.Font.GothamBold
	rarityLabel.TextScaled = true
	rarityLabel.Text = string.upper(rarity)
	rarityLabel.TextColor3 = color
	rarityLabel.TextStrokeTransparency = 0.2
	rarityLabel.Parent = billboard

	if isNew then
		local newLabel = Instance.new("TextLabel")
		newLabel.BackgroundTransparency = 1
		newLabel.Size = UDim2.new(1, 0, 0.3, 0)
		newLabel.Position = UDim2.new(0, 0, 0.85, 0)
		newLabel.Font = Enum.Font.GothamBlack
		newLabel.TextScaled = true
		newLabel.Text = "NEW!"
		newLabel.TextColor3 = Color3.fromRGB(255, 230, 90)
		newLabel.TextStrokeTransparency = 0
		newLabel.Parent = billboard
	end

	-- pop in, hang, fade out -- never lingers past the sequence.
	billboard.Size = UDim2.fromOffset(0, 0)
	local fullSize = UDim2.fromOffset(220, isNew and 100 or 78)
	TweenService:Create(billboard, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = fullSize }):Play()

	task.delay(hangTime, function()
		if billboard.Parent then
			for _, label in billboard:GetChildren() do
				if label:IsA("TextLabel") then
					TweenService:Create(label, TweenInfo.new(0.25), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
				end
			end
		end
	end)
end

local function playReveal(data: RevealPayload)
	local display = CartData.RarityDisplay[data.rarity]
	if not display then
		return
	end

	local color = Color3.new(display.Color[1], display.Color[2], display.Color[3])
	local cover = data.cover
	local coverPart = cover and cover.PrimaryPart

	local totalDuration = display.RevealDuration
	local compressTime = totalDuration * COMPRESS_FRACTION
	local shakeTime = totalDuration * SHAKE_FRACTION
	local launchTime = totalDuration * LAUNCH_FRACTION
	local hangTime = math.max(0.15, totalDuration - compressTime - shakeTime - launchTime)

	local revealPosition = coverPart and coverPart.Position or Vector3.new(0, 3, 0)
	local revealCFrame = coverPart and coverPart.CFrame or CFrame.new(revealPosition)

	if coverPart then
		local compressTween = playCompress(coverPart, compressTime)
		compressTween.Completed:Wait()
		if coverPart.Parent then
			playShake(coverPart, shakeTime, 0.35 + display.IdleParticleRate * 0.02)
			task.wait(shakeTime)
		end
	else
		task.wait(compressTime + shakeTime)
	end

	-- Burst: the cover pops apart here. This Destroy() is local-only (this
	-- client's own view) -- the server independently cleans up the real
	-- Instance shortly after on its own timer (CartSpawnService), so every
	-- other player sees it disappear too, just not on this exact frame.
	local burstParent = (cover and cover.Parent) or Workspace
	playBurst(revealPosition, color, display.BurstParticleCount, burstParent)
	SoundController.PlaySFX("ItemReveal", { PlaybackSpeed = 0.9 + (display.IdleParticleRate * 0.01) })
	if cover then
		cover:Destroy()
	end

	-- The real cart launches upward out of the burst point.
	local template = CartTemplateLookup.Get(data.cartId)
	local revealModel = CartVisuals.PrepareCart(template)
	revealModel.Parent = Workspace
	local revealBody = revealModel.PrimaryPart :: BasePart
	revealBody.CFrame = revealCFrame
	local launchTargetCFrame = revealCFrame * CFrame.new(0, 3.5, 0)

	local startSize = revealBody.Size
	revealBody.Size = startSize * 0.6
	TweenService:Create(revealBody, TweenInfo.new(launchTime, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		CFrame = launchTargetCFrame,
		Size = startSize,
	}):Play()

	playRevealText(revealBody, data.displayName, display.DisplayName, data.isNew, color, hangTime)
	SoundController.PlaySFX("CartCollect", { PlaybackSpeed = display.CollectPitch })

	task.wait(launchTime + hangTime * 0.4)

	-- Hand off to the train -- the real visual cart segment starts exactly
	-- where this reveal ghost is standing, then glides into formation.
	if trainController then
		trainController.AddRevealedCart(data.cartId, revealBody.CFrame)
	end

	task.wait(math.max(0, hangTime * 0.6))
	if revealModel.Parent then
		revealModel:Destroy()
	end
end

function LostCartRevealController.Init()
	trainController = require(script.Parent.TrainController)

	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	local cartRevealed = remotesFolder:FindFirstChild("CartRevealed") :: RemoteEvent
	cartRevealed.OnClientEvent:Connect(function(data: RevealPayload)
		task.spawn(playReveal, data)
	end)

	print("[LostCartRevealController] Init")
end

return LostCartRevealController
