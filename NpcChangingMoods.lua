--[[
	NPC Changing Moods
	Put this Script inside the NPC model (for example, workspace.Melt).

	The NPC needs:
	- A Humanoid
	- A HumanoidRootPart
	- A Head
	- Optional mood label:
	  Head > Overhead > Billboard > Frame > Display

	This script uses PathfindingService, raycasts, Humanoid movement,
	attributes, and BindableEvents. Other server scripts can force a mood with:
	workspace.Melt.SetMood:Fire("ANGRY")
]]

-- Services used by the NPC.
local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")

-- References to the NPC and its important body parts.
local npc = script.Parent
local humanoid = npc:WaitForChild("Humanoid")
local rootPart = npc:WaitForChild("HumanoidRootPart")
local head = npc:WaitForChild("Head")

-- Settings you can safely change without editing the AI code.
local CONFIG = {
	DetectionRadius = 35,
	ReturnDistance = 45,
	DefaultStopDistance = 5,
	WanderRadius = 20,
	UpdateInterval = 0.2,
	PathRefreshInterval = 1,
	MoodMinimumTime = 10,
	MoodMaximumTime = 18,
	ObstacleCheckDistance = 4,
}

-- Every mood has its own movement speed, colour, and behaviour.
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

-- This list is used when picking a random mood.
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
local movementId = 0
local isMoving = false
local lastHealth = humanoid.Health

-- Raycasts should not hit the NPC's own body.
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.FilterDescendantsInstances = { npc }

-- Find the overhead TextLabel without crashing if the UI is missing.
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

-- Creates an event so another server Script can deliberately change the mood.
local setMoodEvent = npc:FindFirstChild("SetMood")

if not setMoodEvent then
	setMoodEvent = Instance.new("BindableEvent")
	setMoodEvent.Name = "SetMood"
	setMoodEvent.Parent = npc
end

-- Stores useful information directly on the NPC model.
npc:SetAttribute("Mood", currentMood)
npc:SetAttribute("State", currentState)

-- Update the screen label, NPC speed, and attributes in one place.
local function setMood(newMood, forcedDuration)
	local moodData = MOODS[newMood]

	if not moodData then
		warn(("'%s' is not a valid NPC mood."):format(tostring(newMood)))
		return
	end

	currentMood = newMood
	humanoid.WalkSpeed = moodData.Speed
	npc:SetAttribute("Mood", newMood)

	if moodLabel then
		moodLabel.Text = newMood
		moodLabel.TextColor3 = moodData.Color
	end

	local moodLength = forcedDuration

	if not moodLength then
		moodLength = random:NextNumber(CONFIG.MoodMinimumTime, CONFIG.MoodMaximumTime)
	end

	nextMoodChange = time() + moodLength
end

-- Randomly chooses a mood, but avoids immediately picking the same one again.
local function chooseRandomMood()
	local chosenMood = currentMood

	while chosenMood == currentMood do
		chosenMood = moodNames[random:NextInteger(1, #moodNames)]
	end

	setMood(chosenMood)
end

-- Checks whether a player's character is alive and usable as a target.
local function getCharacterParts(player)
	local character = player.Character

	if not character then
		return nil, nil
	end

	local targetHumanoid = character:FindFirstChildOfClass("Humanoid")
	local targetRoot = character:FindFirstChild("HumanoidRootPart")

	if not targetHumanoid or not targetRoot then
		return nil, nil
	end

	if targetHumanoid.Health <= 0 then
		return nil, nil
	end

	return targetHumanoid, targetRoot
end

-- Returns true when there is no wall between the NPC and the player.
local function hasLineOfSight(targetCharacter, targetRoot)
	local startPosition = rootPart.Position + Vector3.new(0, 2, 0)
	local direction = targetRoot.Position - startPosition
	local result = workspace:Raycast(startPosition, direction, raycastParams)

	if not result then
		return true
	end

	return result.Instance:IsDescendantOf(targetCharacter)
end

-- Finds the closest living player within the detection radius.
local function getNearestPlayer()
	local closestPlayer = nil
	local closestRoot = nil
	local closestDistance = CONFIG.DetectionRadius

	for _, player in Players:GetPlayers() do
		local _, targetRoot = getCharacterParts(player)

		if not targetRoot then
			continue
		end

		local distance = (targetRoot.Position - rootPart.Position).Magnitude

		if distance >= closestDistance then
			continue
		end

		if not hasLineOfSight(player.Character, targetRoot) then
			continue
		end

		closestPlayer = player
		closestRoot = targetRoot
		closestDistance = distance
	end

	return closestPlayer, closestRoot, closestDistance
end

-- Sends a ray downward so wander points land on the floor instead of in mid-air.
local function getGroundPosition(position)
	local rayStart = position + Vector3.new(0, 60, 0)
	local rayDirection = Vector3.new(0, -150, 0)
	local result = workspace:Raycast(rayStart, rayDirection, raycastParams)

	if result then
		return result.Position
	end

	return position
end

-- Picks a random point around where the NPC originally spawned.
local function getWanderPoint()
	local xOffset = random:NextNumber(-CONFIG.WanderRadius, CONFIG.WanderRadius)
	local zOffset = random:NextNumber(-CONFIG.WanderRadius, CONFIG.WanderRadius)

	local roughPoint = homePosition + Vector3.new(xOffset, 0, zOffset)
	return getGroundPosition(roughPoint)
end

-- Cancels any old path before starting a new one.
local function stopMoving()
	movementId += 1
	isMoving = false
	lastGoal = nil
	humanoid:MoveTo(rootPart.Position)
end

-- Walks along a calculated path. The ID check stops older paths taking control.
local function followPath(goal, pathId)
	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentJumpHeight = 7,
		AgentMaxSlope = 35,
	})

	local success = pcall(function()
		path:ComputeAsync(rootPart.Position, goal)
	end)

	if not success or path.Status ~= Enum.PathStatus.Success then
		if pathId == movementId then
			humanoid:MoveTo(goal)
		end

		return
	end

	for _, waypoint in path:GetWaypoints() do
		if pathId ~= movementId or humanoid.Health <= 0 then
			return
		end

		if waypoint.Action == Enum.PathWaypointAction.Jump then
			humanoid.Jump = true
		end

		humanoid:MoveTo(waypoint.Position)

		local reachedWaypoint = humanoid.MoveToFinished:Wait()

		if not reachedWaypoint then
			return
		end
	end
end

-- Only recalculates a path when the goal has meaningfully changed.
local function requestMove(goal)
	local now = time()
	local goalChanged = not lastGoal or (goal - lastGoal).Magnitude > 5
	local pathIsReady = now - lastPathRequest >= CONFIG.PathRefreshInterval

	if isMoving and not goalChanged then
		return
	end

	if isMoving and not pathIsReady then
		return
	end

	movementId += 1
	local pathId = movementId

	isMoving = true
	lastGoal = goal
	lastPathRequest = now

	task.spawn(function()
		followPath(goal, pathId)

		if pathId == movementId then
			isMoving = false
		end
	end)
end

-- Makes the NPC jump small props in front of it, but not other characters.
local function checkForSmallObstacle()
	local startPosition = rootPart.Position + Vector3.new(0, 1, 0)
	local direction = rootPart.CFrame.LookVector * CONFIG.ObstacleCheckDistance
	local result = workspace:Raycast(startPosition, direction, raycastParams)

	if not result then
		return
	end

	local model = result.Instance:FindFirstAncestorOfClass("Model")

	if model and model:FindFirstChildOfClass("Humanoid") then
		return
	end

	local obstacleTop = result.Instance.Position.Y + (result.Instance.Size.Y / 2)
	local heightDifference = obstacleTop - rootPart.Position.Y

	if heightDifference > 0 and heightDifference <= 4 then
		humanoid.Jump = true
	end
end

-- Decides what the NPC should be doing right now.
local function chooseState(targetRoot, targetDistance)
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

	if targetDistance and targetDistance > CONFIG.ReturnDistance then
		return "Return"
	end

	if (rootPart.Position - homePosition).Magnitude > CONFIG.ReturnDistance then
		return "Return"
	end

	return "Wander"
end

-- Works out where the NPC should move for each mood.
local function getInteractionGoal(targetRoot)
	local moodData = MOODS[currentMood]
	local difference = targetRoot.Position - rootPart.Position
	local distance = difference.Magnitude

	if distance <= moodData.StopDistance then
		return nil
	end

	if moodData.Behaviour == "Chase" then
		return targetRoot.Position
	end

	if moodData.Behaviour == "Sneak" then
		return targetRoot.Position - targetRoot.CFrame.LookVector * 4
	end

	if moodData.Behaviour == "Orbit" then
		local sideOffset = targetRoot.CFrame.RightVector * math.sin(time() * 2) * 7
		return targetRoot.Position + sideOffset
	end

	return targetRoot.Position - difference.Unit * moodData.StopDistance
end

-- Runs every few moments instead of every frame to keep the AI efficient.
local function updateNPC()
	if humanoid.Health <= 0 then
		return
	end

	if time() >= nextMoodChange then
		chooseRandomMood()
	end

	checkForSmallObstacle()

	local targetPlayer, targetRoot, targetDistance = getNearestPlayer()
	currentState = chooseState(targetRoot, targetDistance)
	npc:SetAttribute("State", currentState)

	if currentState == "Interact" and targetRoot then
		local goal = getInteractionGoal(targetRoot)

		if goal then
			requestMove(goal)
		else
			stopMoving()
		end

		if currentMood == "HYPER" and random:NextInteger(1, 5) == 1 then
			humanoid.Jump = true
		end

		return
	end

	if currentState == "Flee" and targetRoot then
		local awayDirection = rootPart.Position - targetRoot.Position

		if awayDirection.Magnitude < 0.1 then
			awayDirection = rootPart.CFrame.LookVector
		end

		local fleeGoal = rootPart.Position + awayDirection.Unit * 22
		requestMove(getGroundPosition(fleeGoal))
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

-- Let another server-side script force a mood when needed.
setMoodEvent.Event:Connect(function(newMood, duration)
	if typeof(newMood) ~= "string" then
		return
	end

	setMood(string.upper(newMood), duration)
end)

-- Taking damage makes the NPC angry for a short time.
humanoid.HealthChanged:Connect(function(newHealth)
	if newHealth < lastHealth and newHealth > 0 then
		setMood("ANGRY", 12)
	end

	lastHealth = newHealth
end)

-- Stop old path tasks when the NPC dies.
humanoid.Died:Connect(function()
	stopMoving()
	npc:SetAttribute("State", "Dead")
end)

-- Start in a calm state.
setMood("CALM")

RunService.Heartbeat:Connect(function()
	local now = time()

	if now - lastUpdate < CONFIG.UpdateInterval then
		return
	end

	lastUpdate = now
	updateNPC()
end)
