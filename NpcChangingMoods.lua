-- Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
-- Variables
local npc = workspace.Melt
local humanoid = npc:WaitForChild("Humanoid")
local rootPart = npc:WaitForChild("HumanoidRootPart")
local head = npc:WaitForChild("Head")
local moodLabel = head.Overhead.Billboard.Frame.Display
local origin = rootPart.Position
local wanderRadiusX = 15
local wanderRadiusZ = 15
local detectRadius = 30
local stopDistance = 5
local mode = "Wander"
local targetPlayer = nil
local lastMove = 0
local moveDelay = 1
local reachedPoint = true
local currentMood = "CALM"
local nextMoodChange = tick() + 5
local moods = {"CALM","ANGRY","LAZY","SCARED","HYPER","SNEAKY","CURIOUS"} -- Moods for later.
local rayPart = Instance.new("Part") -- Ray part for jumping (using moveto and i want to visualise the jump)
rayPart.Name = "JumpRay"
rayPart.Anchored = true
rayPart.CanCollide = false
rayPart.CanQuery = false
rayPart.CanTouch = false
rayPart.Material = Enum.Material.Neon
rayPart.Size = Vector3.new(0.15,0.15,6)
rayPart.Transparency = 0.2
rayPart.Parent = workspace
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = {npc} -- exclude the npc from the ray
local function setMood(newMood) -- set the mood to whatever
	currentMood = newMood
	moodLabel.Text = newMood -- set the text label to the mood and also the colour, furthermore the walkspeed
	if newMood == "CALM" then
		humanoid.WalkSpeed = 10
		moodLabel.TextColor3 = Color3.fromRGB(0,255,0)
	elseif newMood == "ANGRY" then
		humanoid.WalkSpeed = 16
		moodLabel.TextColor3 = Color3.fromRGB(255,0,0)
	elseif newMood == "LAZY" then
		humanoid.WalkSpeed = 7
		moodLabel.TextColor3 = Color3.fromRGB(170,0,255)
	elseif newMood == "SCARED" then
		humanoid.WalkSpeed = 14
		moodLabel.TextColor3 = Color3.fromRGB(0,170,255)
	elseif newMood == "HYPER" then
		humanoid.WalkSpeed = 20
		moodLabel.TextColor3 = Color3.fromRGB(255,255,0)
	elseif newMood == "SNEAKY" then
		humanoid.WalkSpeed = 8
		moodLabel.TextColor3 = Color3.fromRGB(40,40,40)
	elseif newMood == "CURIOUS" then
		humanoid.WalkSpeed = 11
		moodLabel.TextColor3 = Color3.fromRGB(255,170,255)
	end
end
local function randomMood()
	local choice = moods[math.random(1,#moods)] -- select random mood and set it. Then add the mood cooldown of 5 seconds
	setMood(choice)
	nextMoodChange = tick() + 5
end
local function getNearestPlayer()
	local closestPlayer = nil
	local closestDistance = detectRadius
	for _,player in ipairs(Players:GetPlayers()) do -- check all players not just one
		local character = player.Character
		if character then
			local enemyHumanoid = character:FindFirstChild("Humanoid")
			local enemyRoot = character:FindFirstChild("HumanoidRootPart")
			if enemyHumanoid and enemyRoot and enemyHumanoid.Health > 0 then
				local distance = (enemyRoot.Position - rootPart.Position).Magnitude -- Check the displacement between npc and player.
				if distance < closestDistance then
					closestDistance = distance
					closestPlayer = player -- if valid player, store it likewise distance
				end
			end
		end
	end
	return closestPlayer
end
local function getRandomPoint() -- this is for the npc to wonder around. It will randomise a point within a box.
	local offsetX = math.random(-wanderRadiusX,wanderRadiusX)
	local offsetZ = math.random(-wanderRadiusZ,wanderRadiusZ)
	return Vector3.new(origin.X + offsetX,origin.Y,origin.Z + offsetZ)
end
local function obstacleJumpCheck() -- this is where our ray is used
	local lookVector = rootPart.CFrame.LookVector
	local startPos = rootPart.Position
	local direction = lookVector * 6 -- point it ahead of the npc
	local result = workspace:Raycast(startPos,direction,rayParams)
	local endPos = startPos + direction
	local middle = startPos:Lerp(endPos,0.5)
	rayPart.CFrame = CFrame.lookAt(middle,endPos) -- move the ray part to match its the ray position
	rayPart.Size = Vector3.new(0.15,0.15,direction.Magnitude)
	if result then
		local hitPart = result.Instance
		local model = hitPart:FindFirstAncestorOfClass("Model")
		local hitHumanoid = model and model:FindFirstChildOfClass("Humanoid")
		if hitHumanoid then 
			rayPart.Color = Color3.fromRGB(0,255,0) -- if its a character, ignore as we dont want to spam jump over the target
			return
		end
		local topY = hitPart.Position.Y + hitPart.Size.Y / 2
		local myY = rootPart.Position.Y
		if topY - myY <= 5 then -- if the npc is infront of a non player object, jump over it
			rayPart.Color = Color3.fromRGB(255,0,0)
			humanoid.Jump = true -- humanoid built in jump boolean which automatically disables after jump
		else
			rayPart.Color = Color3.fromRGB(255,170,0)
		end
	else
		rayPart.Color = Color3.fromRGB(0,255,0)
	end -- continuously update the ray part colour from red to green or vice versa for visual indication
end
humanoid.MoveToFinished:Connect(function()
	reachedPoint = true -- when arrived at a destination, set reach to poin to true so the wander doesnt spam every millisecond
end)
setMood("CALM") -- default mood to calm
RunService.Heartbeat:Connect(function()
	obstacleJumpCheck() -- always check the jump every frame
	if tick() >= nextMoodChange then -- if we are off cooldown, select a random mood
		randomMood()
	end
	local nearest = getNearestPlayer() -- get the nearest player
	if nearest then
		targetPlayer = nearest
		if currentMood == "SCARED" then -- set our ai modes based on the NPCs' mood
			mode = "Flee"
		elseif currentMood == "LAZY" then
			mode = "Wander"
		else
			mode = "Follow"
		end
	else
		targetPlayer = nil -- if theres no target player and outside of origin position, return to origin. Else start wondering about
		if (rootPart.Position - origin).Magnitude > 4 then
			mode = "Return"
		else
			mode = "Wander"
		end
	end
	if mode == "Follow" and targetPlayer then
		local character = targetPlayer.Character -- start by getting our target players character, hrp and vectors.
		if not character then return end
		local targetRoot = character:FindFirstChild("HumanoidRootPart")
		if not targetRoot then return end
		local offset = targetRoot.Position - rootPart.Position
		local distance = offset.Magnitude
		if distance <= stopDistance then
			humanoid:MoveTo(rootPart.Position) -- move to the player
			return
		end
		if tick() - lastMove >= 0.15 then -- update every 0.15 to prevent intense memory usage
			local goal
			if currentMood == "SNEAKY" then
				goal = targetRoot.Position - targetRoot.CFrame.LookVector * 4 -- move behind them
			elseif currentMood == "CURIOUS" then
				local side = targetRoot.CFrame.RightVector * math.sin(tick() * 2) * 6 -- stand beside them
				goal = targetRoot.Position + side
			else
				goal = targetRoot.Position - offset.Unit * stopDistance -- stop before the player so not spam colliding
			end
			humanoid:MoveTo(goal)
			if currentMood == "HYPER" and math.random(1,4) == 1 then -- spam jump one in 4
				humanoid.Jump = true
			end
			lastMove = tick()
		end
	elseif mode == "Flee" and targetPlayer then
		local character = targetPlayer.Character
		if not character then return end
		local targetRoot = character:FindFirstChild("HumanoidRootPart")
		if not targetRoot then return end
		local offset = rootPart.Position - targetRoot.Position
		if tick() - lastMove >= 0.15 then
			local fleeGoal = rootPart.Position + offset.Unit * 20 -- run the OPPOSITE direction of the player. so if a player chases it runs
			humanoid:MoveTo(fleeGoal)
			lastMove = tick()
		end
	elseif mode == "Return" then
		if tick() - lastMove >= moveDelay then -- gp back to origin. simple
			humanoid:MoveTo(origin)
			lastMove = tick()
		end
	elseif mode == "Wander" then
		local delayTime = moveDelay
		if currentMood == "LAZY" then
			delayTime = 2 -- move about slowly
		elseif currentMood == "ANGRY" then
			delayTime = 0.6 -- move about faster
		elseif currentMood == "HYPER" then
			delayTime = 0.25 -- move about REALLY fast
		end
		if reachedPoint and tick() - lastMove >= delayTime then
			reachedPoint = false
			humanoid:MoveTo(getRandomPoint()) -- compute the wander, and move to it
			if currentMood == "HYPER" then
				humanoid.Jump = true -- jump if hyper
			end
			lastMove = tick() -- store the last move so we can have said 0.15 cooldown.
		end
	end
end)
