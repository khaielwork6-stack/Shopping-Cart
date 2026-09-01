--!strict
-- Shared display formatting (�5.2/�9.1): "1.2K / 3.4M / 5.6B" once a value
-- exceeds 9,999 -- full digit strings become unreadable well before World 3.

local SUFFIXES = { "K", "M", "B", "T", "Qa", "Qi" }

local FormatNumber = {}

function FormatNumber.Format(value: number): string
	local sign = value < 0 and "-" or ""
	local n = math.abs(value)

	if n < 10000 then
		return sign .. string.format("%d", math.floor(n + 0.5))
	end

	local magnitude = 0
	while n >= 1000 and magnitude < #SUFFIXES do
		n /= 1000
		magnitude += 1
	end

	return sign .. string.format("%.1f%s", n, SUFFIXES[magnitude])
end

return FormatNumber
