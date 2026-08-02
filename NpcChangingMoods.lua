-- Connected Discord-GitHub
-- Roblox Username: StepRuji
-- Discord Username: stepruji

--[[
	NPC Mood Controller

	Controls NPC personality, movement, and reactions to players.

	Mood controls personality settings such as speed and behaviour.
	State controls the NPC's current action such as wandering, fleeing,
	or interacting.

	The script is server-sided so NPC decisions have one source of truth.
	Expensive operations such as pathfinding and player checks are limited
	to avoid unnecessary server usage.
]]

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")

local npc = script.Parent
local humanoid = npc:WaitForChild("Humanoid")
local rootPart = npc:WaitForChild("HumanoidRootPart")
local head = npc:WaitForChild("Head")


-- Settings used to balance NPC behaviour.
local CONFIG = {
	DetectionRadius = 35,
	ReturnDistance = 45,
	DefaultStopDistance = 5,
	WanderRadius = 20,

	-- AI updates 5 times per second instead of every frame.
	UpdateInterval = 0.2,

	-- Prevents excessive pathfinding calculations.
	PathRefreshInterval = 1,

	MoodMinimumTime = 10,
	MoodMaximumTime = 18,

	ObstacleCheckDistance = 4,
}


-- Behaviour data is stored separately from logic so new moods can be
-- added without creating more conditional code.
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
-- If a new path is created, older paths are ignored.
local movementId = 0

local isMoving = false
local lastHealth = humanoid.Health

local running = true


-- All connections created by this script are stored here so they can
-- be disconnected when the NPC is destroyed.
local connections = {}
local cleanedUp = false


local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.FilterDescendantsInstances = {npc}



-- Finds the optional overhead mood display.
-- The NPC should still function if the UI is missing.
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



-- Allows other server scripts to change the NPC's mood.
-- A BindableEvent is used because this is server-to-server communication.
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



-- Changes the NPC personality and keeps related systems updated.
-- Keeping this in one place prevents the UI, movement speed, and timers
-- becoming out of sync.
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



-- Selects a different random personality.
-- Avoiding the same mood prevents unnecessary updates.
local function chooseRandomMood()

	local chosenMood = currentMood


	while chosenMood == currentMood do
		chosenMood = moodNames[
			random:NextInteger(1, #moodNames)
		]
	end


	setMood(chosenMood)
end



-- Checks if a player has a valid character that the NPC can target.
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



-- Checks visibility so NPCs do not react to players through walls.
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



-- Finds the nearest visible player.
-- Distance is checked before raycasts because it is cheaper and reduces
-- unnecessary physics checks.
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
			(targetRoot.Position - rootPart.Position).Magnitude


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

-- Finds a valid position on the ground.
-- This prevents random wandering points from spawning above or below the map.
local function getGroundPosition(position)

	local rayStart =
		position + Vector3.new(0, 60, 0)


	local result = workspace:Raycast(
		rayStart,
		Vector3.new(0, -150, 0),
		raycastParams
	)


	if result then
		return result.Position
	end


	return position
end



-- Generates a random location around the NPC's spawn point.
-- Using the original position prevents the NPC slowly drifting away over time.
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


	local point =
		homePosition + Vector3.new(
			xOffset,
			0,
			zOffset
		)


	return getGroundPosition(point)
end



-- Stops the current movement command.
-- Increasing movementId makes running pathfinding tasks ignore themselves.
local function stopMoving()

	if not isMoving then
		return
	end


	movementId += 1

	isMoving = false
	lastGoal = nil


	humanoid:MoveTo(rootPart.Position)
end



-- Calculates and follows a path to a target position.
-- Pathfinding runs separately because Roblox navigation can yield while
-- calculating routes.
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


	-- Ignore paths that are no longer the latest request.
	if not running or pathId ~= movementId then
		return
	end


	if not success
		or path.Status ~= Enum.PathStatus.Success then

		-- Simple movement fallback for areas where
		-- pathfinding cannot create a route.
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



-- Creates movement requests while avoiding unnecessary pathfinding.
-- Recalculating paths too often can become expensive with many NPCs.
local function requestMove(goal)

	if not running then
		return
	end


	local now = time()


	local goalChanged =
		not lastGoal
		or (goal - lastGoal).Magnitude > 5


	local canRefresh =
		now - lastPathRequest >=
		CONFIG.PathRefreshInterval



	if isMoving and not goalChanged then
		return
	end


	if isMoving and not canRefresh then
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



-- Checks for small obstacles that appeared after path creation.
-- This allows the NPC to react to moving objects that were not there before.
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


	-- Ignore players so NPCs do not constantly jump near characters.
	if model
		and model:FindFirstChildOfClass("Humanoid") then

		return
	end


	local obstacleTop =
		result.Instance.Position.Y
		+ (result.Instance.Size.Y / 2)


	local difference =
		obstacleTop - rootPart.Position.Y


	if difference > 0
		and difference <= 4 then

		humanoid.Jump = true
	end
end



-- Chooses the NPC's current objective.
-- Movement is handled separately so different states cannot conflict.
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



-- Calculates where the NPC should stand during interaction.
-- Different moods change positioning without requiring separate AI systems.
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
