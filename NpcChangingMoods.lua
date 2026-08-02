-- Connected Discord-GitHub
-- Roblox Username: StepRuji
-- Discord Username: stepruji

-- Controls NPC mood, movement, and player reactions.
-- Mood controls personality settings while state controls the current action.
-- The server owns decisions so NPC behaviour stays consistent.

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")

local npc = script.Parent
local humanoid = npc:WaitForChild("Humanoid")
local rootPart = npc:WaitForChild("HumanoidRootPart")
local head = npc:WaitForChild("Head")


-- Central settings used to balance NPC behaviour.
local CONFIG = {
	DetectionRadius = 35,
	ReturnDistance = 45,
	DefaultStopDistance = 5,
	WanderRadius = 20,

	-- Limits AI checks instead of running expensive logic every frame.
	UpdateInterval = 0.2,

	-- Prevents unnecessary path recalculation.
	PathRefreshInterval = 1,

	MoodMinimumTime = 10,
	MoodMaximumTime = 18,

	ObstacleCheckDistance = 4,
}


-- Behaviour is stored as data so new moods can be added without creating
-- separate movement systems for every personality.
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
-- If a newer path is created, older movement tasks are ignored.
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


-- Allows other server scripts to change the NPC mood.
-- BindableEvent is used because this communication does not need client access.
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


-- Updates all mood-related systems together so speed, UI, and timers
-- cannot become out of sync.
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


-- Selects a different mood so the NPC does not repeatedly refresh the
-- same behaviour.
local function chooseRandomMood()

	local chosenMood = currentMood

	while chosenMood == currentMood do
		chosenMood = moodNames[
			random:NextInteger(1, #moodNames)
		]
	end

	setMood(chosenMood)
end


-- Makes sure a player has a valid character before the NPC targets them.
-- Players may temporarily have no character while loading or resetting.
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


-- Checks visibility before reacting to players.
-- This prevents NPCs detecting targets through walls.
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
-- Distance checks happen first because they are cheaper than raycasts.
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


-- Finds a valid ground position for wandering and fleeing.
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


-- Generates a random location around the NPC's starting position.
-- Keeping this centred prevents the NPC drifting away over time.
local function getWanderPoint()

	local xOffset = random:NextNumber(
		-CONFIG.WanderRadius,
		CONFIG.WanderRadius
	)

	local zOffset = random:NextNumber(
		-CONFIG.WanderRadius,
		CONFIG.WanderRadius
	)


	return getGroundPosition(
		homePosition + Vector3.new(
			xOffset,
			0,
			zOffset
		)
	)
end

-- Stops the current movement command.
-- Increasing movementId makes older pathfinding tasks ignore themselves
-- if the NPC has already received a newer instruction.
local function stopMoving()

	if not isMoving then
		return
	end


	movementId += 1
	isMoving = false
	lastGoal = nil

	humanoid:MoveTo(rootPart.Position)
end


-- Calculates and follows a path to a destination.
-- This runs separately because path calculations can yield and should not
-- block the main AI decision loop.
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


	if not running or pathId ~= movementId then
		return
	end


	if not success or path.Status ~= Enum.PathStatus.Success then

		-- Fallback movement for simple areas where a path cannot be created.
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


		if waypoint.Action == Enum.PathWaypointAction.Jump then
			humanoid.Jump = true
		end


		humanoid:MoveTo(waypoint.Position)

		local reached = humanoid.MoveToFinished:Wait()

		if not reached then
			return
		end
	end
end


-- Creates movement requests while limiting path calculations.
-- Constantly recalculating paths can become expensive when many NPCs exist.
local function requestMove(goal)

	if not running then
		return
	end


	local now = time()

	local goalChanged =
		not lastGoal
		or (goal - lastGoal).Magnitude > 5


	local pathReady =
		now - lastPathRequest >= CONFIG.PathRefreshInterval


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

		followPath(goal, pathId)


		if running and pathId == movementId then
			isMoving = false
		end
	end)
end


-- Checks for small obstacles that appeared after path creation.
-- This handles simple dynamic objects without constantly rebuilding paths.
local function checkForSmallObstacle()

	local result = workspace:Raycast(
		rootPart.Position + Vector3.new(0, 1, 0),
		rootPart.CFrame.LookVector * CONFIG.ObstacleCheckDistance,
		raycastParams
	)


	if not result then
		return
	end


	local model =
		result.Instance:FindFirstAncestorOfClass("Model")


	if model and model:FindFirstChildOfClass("Humanoid") then
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


-- Decides what the NPC should currently do.
-- Movement is handled separately so different states cannot fight each other.
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


-- Creates a movement target based on the NPC personality.
-- Different moods change positioning without needing separate AI systems.
local function getInteractionGoal(targetRoot)

	local moodData = MOODS[currentMood]

	local difference =
		targetRoot.Position - rootPart.Position


	local distance = difference.Magnitude


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


-- Main decision loop for the NPC.
-- Each update chooses one behaviour so multiple actions cannot override each other.
local function updateNPC()

	if not running or humanoid.Health <= 0 then
		return
	end


	if time() >= nextMoodChange then
		chooseRandomMood()
	end


	checkForSmallObstacle()


	local targetRoot = getNearestPlayer()

	setState(chooseState(targetRoot))


	if currentState == "Interact"
		and targetRoot then

		local goal = getInteractionGoal(targetRoot)


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
			rootPart.Position - targetRoot.Position


		if awayDirection.Magnitude < 0.1 then
			awayDirection = rootPart.CFrame.LookVector
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


-- Cleans up every resource owned by this NPC controller.
-- This prevents connections and running tasks from remaining after removal.
local function cleanup()

	if cleanedUp then
		return
	end


	cleanedUp = true
	running = false
	movementId += 1

	isMoving = false
	lastGoal = nil


	for _, connection in connections do
		connection:Disconnect()
	end


	table.clear(connections)


	if ownsSetMoodEvent
		and setMoodEvent.Parent then

		setMoodEvent:Destroy()
	end
end


table.insert(
	connections,
	setMoodEvent.Event:Connect(function(newMood, duration)

		if typeof(newMood) ~= "string" then
			return
		end

		setMood(
			string.upper(newMood),
			duration
		)

	end)
)


-- Damage changes the NPC mood without needing another polling loop.
table.insert(
	connections,
	humanoid.HealthChanged:Connect(function(newHealth)

		if newHealth < lastHealth
			and newHealth > 0 then

			setMood("ANGRY", 12)
		end


		lastHealth = newHealth
	end)
)


table.insert(
	connections,
	humanoid.Died:Connect(function()

		setState("Dead")
		cleanup()

	end)
)


table.insert(
	connections,
	npc.Destroying:Connect(cleanup)
)


setMood("CALM")


-- Heartbeat only acts as a timer.
-- The interval check keeps expensive AI calculations from running every frame.
table.insert(
	connections,
	RunService.Heartbeat:Connect(function()

		local now = time()


		if not running
			or now - lastUpdate < CONFIG.UpdateInterval then

			return
		end


		lastUpdate = now
		updateNPC()

	end)
)
