if _G.MixiAutoTask then
    pcall(task.cancel, _G.MixiAutoTask)
    _G.MixiAutoTask = nil
end

if _G.MixiHeartbeatConnection then
    pcall(function()
        _G.MixiHeartbeatConnection:Disconnect()
    end)
    _G.MixiHeartbeatConnection = nil
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local Humanoid = Character:WaitForChild("Humanoid")
local RootPart = Character:WaitForChild("HumanoidRootPart")

LocalPlayer.CharacterAdded:Connect(function(newChar)
    Character = newChar
    Humanoid = newChar:WaitForChild("Humanoid")
    RootPart = newChar:WaitForChild("HumanoidRootPart")
    pcall(function()
        Humanoid.HumanoidCollisionType = Enum.HumanoidCollisionType.OuterBox
    end)
end)
pcall(function()
    Humanoid.HumanoidCollisionType = Enum.HumanoidCollisionType.OuterBox
end)
local PathSolver = {}
PathSolver.__index = PathSolver

function PathSolver.new()
    local self = setmetatable({}, PathSolver)
    
    local ok, p2d = pcall(function()
        return Instance.new("Path2D")
    end)
    if ok and p2d then
        self.PathInstance = p2d
    else
        self.PathInstance = nil
    end
    
    self.ControlPoints = {}
    self.Samples = {}
    self.TotalLength = 0
    return self
end

function PathSolver:SetWaypoints(waypoints: {Vector3})
    if #waypoints < 2 then return end
    self.ControlPoints = {}
    local controlPointObjs = {}
    for i, wp in ipairs(waypoints) do
        local pOffset = UDim2.fromOffset(wp.X, wp.Z)
        
        local ok, cp = pcall(function()
            local point = Path2DControlPoint.new()
            point.Position = pOffset
            return point
        end)
        
        if ok and cp then
            table.insert(controlPointObjs, cp)
        end
        table.insert(self.ControlPoints, wp)
    end
    
    if self.PathInstance and #controlPointObjs > 0 then
        pcall(function()
            self.PathInstance:SetControlPoints(controlPointObjs)
            self.TotalLength = self.PathInstance:GetLength()
        end)
    end
end

function PathSolver:SampleTrajectory(stepDistance: number): { {Position: Vector3, Tangent: Vector3} }
    local trajectory = {}
    local totalDist = self.TotalLength
    
    if totalDist <= 0 or not self.PathInstance then
        for i = 1, #self.ControlPoints - 1 do
            local pA = self.ControlPoints[i]
            local pB = self.ControlPoints[i + 1]
            local segLen = (pB - pA).Magnitude
            local steps = math.max(1, math.floor(segLen / (stepDistance or 2)))
            for s = 0, steps do
                local alpha = s / steps
                local pos = pA:Lerp(pB, alpha)
                local tangent = (pB - pA).Unit
                table.insert(trajectory, { Position = pos, Tangent = tangent })
            end
        end
        return trajectory
    end

    local currentLen = 0
    while currentLen <= totalDist do
        local okPos, uPos = pcall(function()
            return self.PathInstance:GetPositionOnCurveArcLength(currentLen)
        end)
        local okTan, uTan = pcall(function()
            return self.PathInstance:GetTangentOnCurveArcLength(currentLen)
        end)
        
        if okPos and uPos then
            local progressAlpha = math.clamp(currentLen / totalDist, 0, 1)
            local startY = self.ControlPoints[1].Y
            local targetY = self.ControlPoints[#self.ControlPoints].Y
            local currentY = startY + (targetY - startY) * progressAlpha
            
            local worldPos = Vector3.new(uPos.X.Offset, currentY, uPos.Y.Offset)
            local worldTan = Vector3.new(1, 0, 0)
            if okTan and uTan then
                worldTan = Vector3.new(uTan.X.Offset, 0, uTan.Y.Offset).Unit
            end
            
            table.insert(trajectory, { Position = worldPos, Tangent = worldTan })
        end
        currentLen += (stepDistance or 2)
    end
    
    return trajectory
end

local StageScanner = {}

function StageScanner.GetStageWaypoints(): {Vector3}
    local waypoints = {}
    local stageContainers = {}
    for _, child in ipairs(Workspace:GetChildren()) do
        local nameLower = string.lower(child.Name)
        if string.find(nameLower, "stage") or string.find(nameLower, "checkpoint") or string.find(nameLower, "obby") then
            table.insert(stageContainers, child)
        end
    end
    
    for _, container in ipairs(stageContainers) do
        local parts = {}
        for _, desc in ipairs(container:GetDescendants()) do
            if desc:IsA("BasePart") then
                table.insert(parts, desc)
            end
        end
        table.sort(parts, function(a, b)
            return a.Position.Z < b.Position.Z
        end)
        
        for _, part in ipairs(parts) do
            table.insert(waypoints, part.Position + Vector3.new(0, 3, 0))
        end
    end
    
    return waypoints
end

local RunnerEngine = {}
RunnerEngine.IsRunning = false

function RunnerEngine.Start()
    if RunnerEngine.IsRunning then return end
    RunnerEngine.IsRunning = true
    _G.MixiAutoTask = task.spawn(function()
        local waypoints = StageScanner.GetStageWaypoints()
        
        if #waypoints < 2 then
            local origin = RootPart.Position
            waypoints = {
                origin,
                origin + Vector3.new(0, 5, -25),
                origin + Vector3.new(10, 8, -50),
                origin + Vector3.new(0, 5, -75),
                origin + Vector3.new(0, 2, -100)
            }
        end
        
        local solver = PathSolver.new()
        solver:SetWaypoints(waypoints)
        local trajectory = solver:SampleTrajectory(1.5)
        local nodeIndex = 1
        local moveSpeed = 35
        
        _G.MixiHeartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
            if not RunnerEngine.IsRunning or nodeIndex > #trajectory then
                if _G.MixiHeartbeatConnection then
                    _G.MixiHeartbeatConnection:Disconnect()
                    _G.MixiHeartbeatConnection = nil
                end
                RunnerEngine.IsRunning = false
                return
            end
            
            if not RootPart or not RootPart.Parent then return end
            
            local targetNode = trajectory[nodeIndex]
            local targetPos = targetNode.Position
            local targetTan = targetNode.Tangent
            local targetCFrame = CFrame.lookAlong(targetPos, targetTan)
            local stepAlpha = math.clamp((moveSpeed * deltaTime) / math.max(0.1, (targetPos - RootPart.Position).Magnitude), 0, 1)
            RootPart.CFrame = RootPart.CFrame:Lerp(targetCFrame, stepAlpha)
            RootPart.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            RootPart.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
            
            if (RootPart.Position - targetPos).Magnitude < 2.5 then
                nodeIndex += 1
            end
        end)
    end)
end

function RunnerEngine.Stop()
    RunnerEngine.IsRunning = false
    if _G.MixiAutoTask then
        pcall(task.cancel, _G.MixiAutoTask)
        _G.MixiAutoTask = nil
    end
    if _G.MixiHeartbeatConnection then
        pcall(function()
            _G.MixiHeartbeatConnection:Disconnect()
        end)
        _G.MixiHeartbeatConnection = nil
    end
end

RunnerEngine.Start()

return {
    PathSolver = PathSolver,
    StageScanner = StageScanner,
    RunnerEngine = RunnerEngine,
    BANNER = BANNER
}
