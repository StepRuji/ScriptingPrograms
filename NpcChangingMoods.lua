-- Connected Discord-GitHub
-- Roblox Username: StepRuji
-- Discord Username: stepruji

--[[
	NPC Mood Controller

	Controls NPC mood, movement, and reactions to players.

	Mood controls the NPC's personality, such as speed and behaviour.
	State controls the current action, such as wandering, interacting,
	or fleeing.

	This is handled on the server so NPC decisions have one source of truth.
	AI updates and pathfinding are limited to avoid unnecessary server usage.
]]


local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")


local npc = script.Parent
local humanoid = npc:WaitForChild("Humanoid")
local rootPart = npc:WaitForChild("HumanoidRootPart")
local head = npc:WaitForChild("Head")


-- Central settings for balancing NPC behaviour.
-- Keeping these values together makes adjustments easier without changing logic.
local CONFIG = {
	DetectionRadius = 35,
	ReturnDistance = 45,
	DefaultStopDistance = 5,
	WanderRadius = 20,

	-- The AI does not need to update every frame.
	-- Running decisions 5 times per second keeps behaviour responsive while
	-- reducing server load with multiple NPCs.
	UpdateInterval = 0.2,

	-- Pathfinding is expensive, so routes are not constantly recalculated.
	PathRefreshInterval = 1,

	MoodMinimumTime = 10,
	MoodMaximumTime = 18,

	ObstacleCheckDistance = 4,
}


-- Mood data is separated from the behaviour logic.
-- Adding a new personality only requires adding data instead of creating
-- another set of movement conditions.
local MOODS = {

	CALM = {
		Speed = 10,
		Color = Color3.fromRGB(92, 220, 110),
		Behaviour = "Follow",
		StopDistance = 5,
	},

	ANGRY = {
		Speed = 16,
		Color = Color3.fromRGB(235, 75, 75),
		Behaviour = "Chase",
		StopDistance = 2.5,
	},

	LAZY = {
		Speed = 7,
		Color = Color3.fromRGB(165, 115, 235),
		Behaviour = "Ignore",
		StopDistance = 8,
	},

	SCARED = {
		Speed = 15,
		Color = Color3.fromRGB(80, 185, 255),
		Behaviour = "Flee",
		StopDistance = 12,
	},

	HYPER = {
		Speed = 20,
		Color = Color3.fromRGB(255, 225, 65),
		Behaviour = "Follow",
		StopDistance = 4,
	},

	SNEAKY = {
		Speed = 9,
		Color = Color3.fromRGB(75, 75, 75),
		Behaviour = "Sneak",
		StopDistance = 4,
	},

	CURIOUS = {
		Speed = 11,
		Color = Color3.fromRGB(255, 150, 225),
		Behaviour = "Orbit",
		StopDistance = 6,
	},
}


local moodNames = {
	"CALM",
	"ANGRY",
	"LAZY",
	"SCARED",
	"HYPER",
	"SNEAKY",
	"CURIOUS",
}


local random = Random.new()

local homePosition = rootPart.Position

local currentMood = "CALM"
local currentState = "Wander"

local nextMoodChange = 0
local lastUpdate = 0

local lastPathRequest = 0
local lastGoal = nil


-- Used to cancel outdated movement requests.
-- If a newer command is created, older pathfinding results are ignored.
local movementId = 0


local isMoving = false
local lastHealth = humanoid.Health

local running = true


-- Connections are stored so they can all be disconnected during cleanup.
local connections = {}
local cleanedUp = false


local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.FilterDescendantsInstances = {npc}


-- Finds the optional mood display above the NPC.
-- The AI should continue working even if the UI is missing.
local function findMoodLabel()

	local overhead = head:FindFirstChild("Overhead")

	if not overhead then
		return nil
	end


	local billboard = overhead:FindFirstChild("Billboard")

	if not billboard then
		return nil
	end


	local frame = billboard:FindFirstChild("Frame")

	if not frame then
		return nil
	end


	local display = frame:FindFirstChild("Display")

	if display and display:IsA("TextLabel") then
		return display
	end


	return nil
end


local moodLabel = findMoodLabel()



-- Allows other server scripts to change the NPC personality.
-- A BindableEvent is used because this communication stays inside the server.
local setMoodEvent = npc:FindFirstChild("SetMood")

local ownsSetMoodEvent = false


if not setMoodEvent then

	setMoodEvent = Instance.new("BindableEvent")
	setMoodEvent.Name = "SetMood"
	setMoodEvent.Parent = npc

	ownsSetMoodEvent = true
end



npc:SetAttribute("Mood", currentMood)
npc:SetAttribute("State", currentState)



local function setState(newState)

	if currentState == newState then
		return
	end


	currentState = newState
	npc:SetAttribute("State", newState)
end



-- Updates every system connected to the NPC mood.
-- Keeping this in one function prevents movement speed, UI, and timers
-- becoming different values.
local function setMood(newMood, forcedDuration)

	local moodData = MOODS[newMood]


	if not moodData then
		warn("Invalid NPC mood:", newMood)
		return
	end


	currentMood = newMood

	humanoid.WalkSpeed = moodData.Speed


	if npc:GetAttribute("Mood") ~= newMood then
		npc:SetAttribute("Mood", newMood)
	end


	if moodLabel then
		moodLabel.Text = newMood
		moodLabel.TextColor3 = moodData.Color
	end



	local duration = forcedDuration


	if not duration then

		duration = random:NextNumber(
			CONFIG.MoodMinimumTime,
			CONFIG.MoodMaximumTime
		)

	end


	nextMoodChange = time() + duration
end



-- Changes personality randomly without repeating the same mood.
-- This avoids unnecessary updates that do not actually change behaviour.
local function chooseRandomMood()

	local chosenMood = currentMood


	while chosenMood == currentMood do

		chosenMood = moodNames[
			random:NextInteger(
				1,
				#moodNames
			)
		]

	end


	setMood(chosenMood)
end



-- Makes sure a player is a valid target before using their character.
-- Players can temporarily have no character while loading or resetting.
local function getCharacterParts(player)

	local character = player.Character


	if not character then
		return nil, nil
	end


	local targetHumanoid =
		character:FindFirstChildOfClass("Humanoid")


	local targetRoot =
		character:FindFirstChild("HumanoidRootPart")



	if not targetHumanoid or not targetRoot then
		return nil, nil
	end


	if targetHumanoid.Health <= 0 then
		return nil, nil
	end


	return targetHumanoid, targetRoot
end



-- Checks visibility before allowing the NPC to react.
-- Without this, the NPC could detect players through walls.
local function hasLineOfSight(targetCharacter, targetRoot)

	local startPosition =
		rootPart.Position + Vector3.new(0, 2, 0)


	local direction =
		targetRoot.Position - startPosition


	local result = workspace:Raycast(
		startPosition,
		direction,
		raycastParams
	)


	if not result then
		return true
	end


	return result.Instance:IsDescendantOf(targetCharacter)
end



-- Finds the closest visible player.
-- Distance checks happen before raycasts because they are cheaper,
-- reducing physics checks when many players are present.
local function getNearestPlayer()

	local closestRoot = nil
	local closestDistance = CONFIG.DetectionRadius


	for _, player in Players:GetPlayers() do

		local _, targetRoot =
			getCharacterParts(player)


		if not targetRoot then
			continue
		end


		local distance =
			(
				targetRoot.Position
				- rootPart.Position
			).Magnitude



		if distance >= closestDistance then
			continue
		end


		if not hasLineOfSight(
			player.Character,
			targetRoot
		) then
			continue
		end


		closestRoot = targetRoot
		closestDistance = distance

	end


	return closestRoot
end



-- Converts a random position into a point on the map.
-- This prevents wandering destinations from being placed in the air.
local function getGroundPosition(position)

	local result = workspace:Raycast(
		position + Vector3.new(0, 60, 0),
		Vector3.new(0, -150, 0),
		raycastParams
	)


	if result then
		return result.Position
	end


	return position
end



-- Creates a random wandering location around the original spawn.
-- Using homePosition prevents the NPC slowly moving away over time.
local function getWanderPoint()

	local xOffset =
		random:NextNumber(
			-CONFIG.WanderRadius,
			CONFIG.WanderRadius
		)


	local zOffset =
		random:NextNumber(
			-CONFIG.WanderRadius,
			CONFIG.WanderRadius
		)



	return getGroundPosition(
		homePosition
			+ Vector3.new(
				xOffset,
				0,
				zOffset
			)
	)
end

-- Stops the current movement command.
-- Incrementing movementId prevents older pathfinding tasks from controlling
-- the NPC after a newer decision has been made.
local function stopMoving()

	if not isMoving then
		return
	end


	movementId += 1

	isMoving = false
	lastGoal = nil


	humanoid:MoveTo(rootPart.Position)
end



-- Creates and follows a path to a destination.
-- Pathfinding can yield while Roblox calculates routes, so it runs separately
-- from the main AI update loop.
local function followPath(goal, pathId)

	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentJumpHeight = 7,
		AgentMaxSlope = 35,
	})


	local success = pcall(function()

		path:ComputeAsync(
			rootPart.Position,
			goal
		)

	end)



	-- Ignore old paths if the NPC has already received a newer command.
	if not running or pathId ~= movementId then
		return
	end



	if not success
		or path.Status ~= Enum.PathStatus.Success then

		-- Direct movement acts as a fallback for simple areas where
		-- pathfinding cannot generate a route.
		humanoid:MoveTo(goal)

		humanoid.MoveToFinished:Wait()

		return
	end



	for _, waypoint in path:GetWaypoints() do

		if not running
			or pathId ~= movementId
			or humanoid.Health <= 0 then

			return
		end



		if waypoint.Action ==
			Enum.PathWaypointAction.Jump then

			humanoid.Jump = true
		end



		humanoid:MoveTo(
			waypoint.Position
		)


		local reached =
			humanoid.MoveToFinished:Wait()



		if not reached then
			return
		end

	end
end



-- Creates movement requests while preventing excessive path calculations.
-- Recalculating paths too often can become expensive with many NPCs.
local function requestMove(goal)

	if not running then
		return
	end


	local now = time()


	local goalChanged =
		not lastGoal
		or (goal - lastGoal).Magnitude > 5


	local pathReady =
		now - lastPathRequest >=
		CONFIG.PathRefreshInterval



	if isMoving and not goalChanged then
		return
	end


	if isMoving and not pathReady then
		return
	end



	movementId += 1

	local pathId = movementId


	isMoving = true
	lastGoal = goal
	lastPathRequest = now



	task.spawn(function()

		followPath(
			goal,
			pathId
		)


		if running and pathId == movementId then
			isMoving = false
		end

	end)
end



-- Detects nearby obstacles that were not present when the path was created.
-- This allows the NPC to react to simple dynamic objects.
local function checkForSmallObstacle()

	local result = workspace:Raycast(
		rootPart.Position + Vector3.new(0, 1, 0),
		rootPart.CFrame.LookVector
			* CONFIG.ObstacleCheckDistance,
		raycastParams
	)


	if not result then
		return
	end



	local model =
		result.Instance:FindFirstAncestorOfClass("Model")


	-- Ignore characters to prevent unnecessary jumping near players.
	if model
		and model:FindFirstChildOfClass("Humanoid") then

		return
	end



	local obstacleTop =
		result.Instance.Position.Y
		+ (result.Instance.Size.Y / 2)


	local heightDifference =
		obstacleTop - rootPart.Position.Y



	if heightDifference > 0
		and heightDifference <= 4 then

		humanoid.Jump = true
	end
end



-- Chooses the NPC's current objective.
-- Separating state selection from movement prevents different behaviours
-- from fighting over control.
local function chooseState(targetRoot)

	local moodData = MOODS[currentMood]


	if targetRoot then

		if moodData.Behaviour == "Flee" then
			return "Flee"
		end


		if moodData.Behaviour == "Ignore" then
			return "Wander"
		end


		return "Interact"
	end



	if (rootPart.Position - homePosition).Magnitude
		> CONFIG.ReturnDistance then

		return "Return"
	end



	return "Wander"
end



-- Calculates where the NPC should move when interacting with players.
-- Different personalities change positioning without needing separate systems.
local function getInteractionGoal(targetRoot)

	local moodData = MOODS[currentMood]


	local difference =
		targetRoot.Position - rootPart.Position


	local distance =
		difference.Magnitude



	if distance <= moodData.StopDistance then
		return nil
	end



	if moodData.Behaviour == "Chase" then
		return targetRoot.Position
	end



	if moodData.Behaviour == "Sneak" then

		return targetRoot.Position
			- targetRoot.CFrame.LookVector * 4

	end



	if moodData.Behaviour == "Orbit" then

		local offset =
			targetRoot.CFrame.RightVector
			* math.sin(time() * 2)
			* 7


		return targetRoot.Position + offset

	end



	return targetRoot.Position
		- difference.Unit * moodData.StopDistance
end



-- Main AI decision function.
-- Each update decides one action, preventing multiple behaviours from
-- sending movement commands at the same time.
local function updateNPC()

	if not running
		or humanoid.Health <= 0 then

		return
	end



	if time() >= nextMoodChange then
		chooseRandomMood()
	end



	checkForSmallObstacle()



	local targetRoot =
		getNearestPlayer()


	setState(
		chooseState(targetRoot)
	)



	if currentState == "Interact"
		and targetRoot then

		local goal =
			getInteractionGoal(targetRoot)


		if goal then
			requestMove(goal)
		else
			stopMoving()
		end


		if currentMood == "HYPER"
			and random:NextInteger(1, 5) == 1 then

			humanoid.Jump = true
		end


		return
	end



	if currentState == "Flee"
		and targetRoot then

		local awayDirection =
			rootPart.Position
			- targetRoot.Position


		if awayDirection.Magnitude < 0.1 then
			awayDirection =
				rootPart.CFrame.LookVector
		end


		requestMove(
			getGroundPosition(
				rootPart.Position
				+ awayDirection.Unit * 22
			)
		)


		return
	end



	if currentState == "Return" then

		requestMove(homePosition)

		return
	end



	if not isMoving then
		requestMove(getWanderPoint())
	end
end
