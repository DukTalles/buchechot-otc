-- ========================================
-- Task Board Module
-- Sistema de Tasks com 3 cards de monstros
-- Sistema de reroll e lock
-- ========================================

local taskWindow = nil
local taskButton = nil
local selectedTab = "facil"
local currentTasks = {}  -- Tasks atuais (3 por categoria)
local lockedTasks = {}   -- Tasks travadas (não sofrem reroll)
local rerollsLeft = 3
local OPCODE_TASK = 216
local cachedTaskData = {}  -- Cache de dados de tasks por categoria (para atualização em tempo real)

-- ========================================
-- FUNCOES AUXILIARES
-- ========================================
function formatNumber(num)
    if not num then return "0" end
    num = tonumber(num) or 0
    if num >= 1000000 then
        return string.format("%.1fM", num / 1000000)
    elseif num >= 1000 then
        return string.format("%.0fK", num / 1000)
    end
    return tostring(math.floor(num))
end

-- ========================================
-- INICIALIZACAO
-- ========================================
function init()
    connect(g_game, {
        onGameStart = onGameStart,
        onGameEnd = onGameEnd
    })

    ProtocolGame.registerExtendedOpcode(OPCODE_TASK, parseOpcode)

    if g_game.isOnline() then
        onGameStart()
    end
end

function terminate()
    disconnect(g_game, {
        onGameStart = onGameStart,
        onGameEnd = onGameEnd
    })

    ProtocolGame.unregisterExtendedOpcode(OPCODE_TASK)

    destroyWindow()
    
    if taskButton then
        taskButton:destroy()
        taskButton = nil
    end
end

function onGameStart()
    createWindow()
    createButton()
end

function onGameEnd()
    destroyWindow()
    if taskButton then
        taskButton:destroy()
        taskButton = nil
    end
    -- Limpar cache ao desconectar
    cachedTaskData = {}
end

-- ========================================
-- CRIACAO DA JANELA
-- ========================================
function createWindow()
    destroyWindow()
    
    taskWindow = g_ui.displayUI('tasksystem')
    if taskWindow then
        taskWindow:setVisible(false)
        setupTabs()
        setupControls()
        setupCards()
    end
end

function destroyWindow()
    if taskWindow then
        taskWindow:destroy()
        taskWindow = nil
    end
    currentTasks = {}
    lockedTasks = {}
end

function createButton()
    if taskButton then
        taskButton:destroy()
        taskButton = nil
    end
    
    if modules.game_mainpanel and modules.game_mainpanel.addStoreButton then
        taskButton = modules.game_mainpanel.addStoreButton(
            'taskSystemButton',
            tr('Task Board - Hunt monsters and earn rewards!'),
            '/modules/game_tasksystem/images/task_large',
            toggleWindow,
            false
        )
        if taskButton then
            taskButton:setText('Task')
            taskButton:setTextOffset(topoint('0 2'))
            taskButton:setFont('verdana-11px-rounded')
            taskButton:setColor('#ffffff')
        end
    end
end

-- ========================================
-- COMUNICACAO COM SERVIDOR
-- ========================================
function sendOpcode(data)
    local protocolGame = g_game.getProtocolGame()
    if protocolGame then
        protocolGame:sendExtendedOpcode(OPCODE_TASK, json.encode(data))
    end
end

function parseOpcode(protocol, opcode, buffer)
    local data = json.decode(buffer)
    if not data then return end
    
    if data.action == "taskList" then
        updateTaskList(data)
    elseif data.action == "taskStarted" then
        onTaskStarted(data)
    elseif data.action == "taskFinished" then
        onTaskFinished(data)
    elseif data.action == "taskCancelled" then
        onTaskCancelled(data)
    elseif data.action == "rerollResult" then
        onRerollResult(data)
    elseif data.action == "buyRerollResult" then
        onBuyRerollResult(data)
    elseif data.action == "killUpdate" then
        onKillUpdate(data)
    elseif data.action == "message" then
        showMessage(data.text, data.color or "white")
    end
end

-- Atualizar kills em tempo real
function onKillUpdate(data)
    if not data.monsterId or not data.category then return end
    
    -- Sempre atualizar o cache (mesmo com janela fechada)
    if not cachedTaskData[data.category] then
        cachedTaskData[data.category] = {}
    end
    cachedTaskData[data.category][data.monsterId] = {
        kills = data.kills,
        total = data.total
    }
    
    -- Se a janela não existe, não precisa atualizar o visual
    if not taskWindow then return end
    
    -- Atualizar dados locais se estamos na mesma categoria
    if data.category == selectedTab then
        for i, task in ipairs(currentTasks) do
            if task.monsterId == data.monsterId then
                task.kills = data.kills
                task.total = data.total
                break
            end
        end
        
        -- Atualizar o card correspondente
        local cardsPanel = taskWindow:getChildById('cardsPanel')
        if not cardsPanel then return end
        
        for i = 1, 3 do
            local card = cardsPanel:getChildById('card' .. i)
            if card and currentTasks[i] and currentTasks[i].monsterId == data.monsterId then
                local killsLabel = card:getChildById('killsLabel')
                if killsLabel then
                    killsLabel:setText(tostring(data.kills) .. " / " .. tostring(data.total) .. " kills")
                    -- Piscar verde quando atualiza
                    killsLabel:setColor("#00ff00")
                    scheduleEvent(function()
                        if killsLabel then
                            killsLabel:setColor("#ffcc00")
                        end
                    end, 500)
                end
                
                -- Atualizar botões se task completou
                if data.kills >= data.total then
                    local selectBtn = card:getChildById('selectButton')
                    local cancelBtn = card:getChildById('cancelButton')
                    if selectBtn then
                        selectBtn:setText(tr('Claim Reward'))
                        selectBtn:setEnabled(true)
                    end
                    if cancelBtn then
                        cancelBtn:setVisible(false)
                    end
                end
                break
            end
        end
    end
end

function onBuyRerollResult(data)
    if data.success then
        rerollsLeft = data.rerolls or rerollsLeft
        updateRerollCount()
        showMessage(data.message, "green")
    else
        showMessage(data.message, "red")
    end
end

function buyReroll(amount)
    amount = amount or 1
    sendOpcode({action = "buyReroll", category = selectedTab, amount = amount})
end

function requestTaskData()
    sendOpcode({action = "getTaskList", category = selectedTab})
end

-- ========================================
-- INTERFACE - ABAS
-- ========================================
function setupTabs()
    if not taskWindow then return end

    local tabBar = taskWindow:getChildById('tabBar')
    if not tabBar then return end

    local tabs = {
        {id = 'tabFacil', name = 'facil'},
        {id = 'tabMedio', name = 'medio'},
        {id = 'tabDificil', name = 'dificil'},
        {id = 'tabHardcore', name = 'hardcore'},
        {id = 'tabBoss', name = 'boss'}
    }

    for _, tab in ipairs(tabs) do
        local tabWidget = tabBar:getChildById(tab.id)
        if tabWidget then
            tabWidget.onClick = function() selectTab(tab.name) end
        end
    end

    selectTab("facil")
end

function selectTab(tabName)
    if not taskWindow then return end

    selectedTab = tabName
    lockedTasks = {}  -- Resetar locks ao trocar de aba

    local tabBar = taskWindow:getChildById('tabBar')
    if not tabBar then return end

    local tabs = {"facil", "medio", "dificil", "hardcore", "boss"}
    for _, tab in ipairs(tabs) do
        local tabWidget = tabBar:getChildById('tab' .. tab:gsub("^%l", string.upper))
        if tabWidget then
            tabWidget:setOn(tab == tabName)
        end
    end

    requestTaskData()
end

-- ========================================
-- INTERFACE - CONTROLES
-- ========================================
function setupControls()
    if not taskWindow then return end

    local controlPanel = taskWindow:getChildById('controlPanel')
    if not controlPanel then return end

    local buttonPanel = controlPanel:getChildById('buttonPanel')
    if buttonPanel then
        local rerollButton = buttonPanel:getChildById('rerollButton')
        if rerollButton then
            rerollButton.onClick = function()
                rerollTasks()
            end
        end
    end

    updateRerollCount()
end

function updateRerollCount()
    if not taskWindow then return end

    local controlPanel = taskWindow:getChildById('controlPanel')
    if not controlPanel then return end

    local rerollInfoPanel = controlPanel:getChildById('rerollInfoPanel')
    if rerollInfoPanel then
        local rerollCountLabel = rerollInfoPanel:getChildById('rerollCount')
        if rerollCountLabel then
            rerollCountLabel:setText(tostring(rerollsLeft))
            if rerollsLeft > 0 then
                rerollCountLabel:setColor("#00ff00")
            else
                rerollCountLabel:setColor("#ff4444")
            end
        end
    end

    local buttonPanel = controlPanel:getChildById('buttonPanel')
    if buttonPanel then
        local rerollButton = buttonPanel:getChildById('rerollButton')
        if rerollButton then
            rerollButton:setEnabled(rerollsLeft > 0)
        end
    end
end

-- ========================================
-- INTERFACE - CARDS
-- ========================================
function setupCards()
    if not taskWindow then return end

    local cardsPanel = taskWindow:getChildById('cardsPanel')
    if not cardsPanel then return end

    for i = 1, 3 do
        local card = cardsPanel:getChildById('card' .. i)
        if card then
            local selectBtn = card:getChildById('selectButton')
            if selectBtn then
                selectBtn.onClick = function()
                    selectTask(i)
                end
            end

            local cancelBtn = card:getChildById('cancelButton')
            if cancelBtn then
                cancelBtn.onClick = function()
                    cancelTask(i)
                end
            end

            local lockBtn = card:getChildById('lockCheck')
            if lockBtn then
                lockBtn.onCheckChange = function(widget, checked)
                    toggleLock(i, checked)
                end
            end
        end
    end
end

function updateTaskList(data)
    currentTasks = data.tasks or {}
    rerollsLeft = data.rerolls or 3
    
    -- Aplicar dados do cache (kills atualizados em tempo real)
    local category = data.category or selectedTab
    if cachedTaskData[category] then
        for i, task in ipairs(currentTasks) do
            if task.monsterId and cachedTaskData[category][task.monsterId] then
                task.kills = cachedTaskData[category][task.monsterId].kills
                task.total = cachedTaskData[category][task.monsterId].total
            end
        end
    end
    
    updateRerollCount()
    updateCards()
end

function updateCards()
    if not taskWindow then return end

    local cardsPanel = taskWindow:getChildById('cardsPanel')
    if not cardsPanel then return end

    for i = 1, 3 do
        local card = cardsPanel:getChildById('card' .. i)
        if card then
            local task = currentTasks[i]
            if task then
                updateCard(card, task, i)
                card:setVisible(true)
            else
                card:setVisible(false)
            end
        end
    end
end

function updateCard(card, task, index)
    if not card or not task then return end

    -- Nome do monstro (no headerPanel)
    local headerPanel = card:getChildById('headerPanel')
    if headerPanel then
        local nameLabel = headerPanel:getChildById('monsterName')
        if nameLabel then
            nameLabel:setText(task.monsterName or "Unknown")
        end
    end

    -- Criatura
    local creature = card:getChildById('monsterCreature')
    if creature and task.looktype then
        creature:setOutfit({type = task.looktype})
        -- Ativar animação no objeto Creature dentro do UICreature
        local creatureObj = creature:getCreature()
        if creatureObj then
            creatureObj:setAnimate(true)
        end
    end

    -- Kills
    local killsLabel = card:getChildById('killsLabel')
    if killsLabel then
        killsLabel:setText(tostring(task.kills or 0) .. " / " .. tostring(task.total or 0) .. " kills")
    end

    -- Rewards
    local rewardPanel = card:getChildById('rewardPanel')
    if rewardPanel then
        local expLabel = rewardPanel:getChildById('expReward')
        if expLabel then
            expLabel:setText("+ " .. formatNumber(task.expReward or 0) .. " XP")
        end

        local itemLabel = rewardPanel:getChildById('itemReward')
        if itemLabel then
            if task.itemRewardCount and task.itemRewardCount > 0 then
                itemLabel:setText("+ " .. task.itemRewardCount .. "x " .. (task.itemRewardName or "Item"))
            else
                itemLabel:setText("")
            end
        end
    end

    -- Botão Select
    local selectBtn = card:getChildById('selectButton')
    local cancelBtn = card:getChildById('cancelButton')
    
    if selectBtn then
        if task.started then
            if task.kills >= task.total then
                selectBtn:setText(tr('Claim Reward'))
                selectBtn:setEnabled(true)
                if cancelBtn then cancelBtn:setVisible(false) end
            else
                selectBtn:setText(tr('In Progress'))
                selectBtn:setEnabled(false)
                if cancelBtn then cancelBtn:setVisible(true) end
            end
        else
            selectBtn:setText(tr('Select Task'))
            selectBtn:setEnabled(true)
            if cancelBtn then cancelBtn:setVisible(false) end
        end
    end

    -- Lock checkbox
    local lockBtn = card:getChildById('lockCheck')
    if lockBtn then
        lockBtn:setChecked(lockedTasks[index] == true)
        -- Desabilitar lock se task já foi iniciada
        lockBtn:setEnabled(not task.started)
    end
end

-- ========================================
-- ACOES
-- ========================================
function selectTask(index)
    local task = currentTasks[index]
    if not task then
        showMessage("Task não encontrada!", "red")
        return
    end

    if task.started and task.kills >= task.total then
        -- Finalizar task
        sendOpcode({
            action = "finishTask",
            category = selectedTab,
            monsterId = task.monsterId
        })
    elseif not task.started then
        -- Iniciar task
        sendOpcode({
            action = "startTask",
            category = selectedTab,
            monsterId = task.monsterId
        })
    end
end

function toggleLock(index, locked)
    lockedTasks[index] = locked
end

function cancelTask(index)
    local task = currentTasks[index]
    if not task then
        showMessage("Task não encontrada!", "red")
        return
    end

    if not task.started then
        showMessage("Esta task não foi iniciada!", "red")
        return
    end

    if task.kills >= task.total then
        showMessage("Esta task já está completa! Resgate a recompensa.", "red")
        return
    end

    -- Cancelar task
    sendOpcode({
        action = "cancelTask",
        category = selectedTab,
        monsterId = task.monsterId
    })
end

function rerollTasks()
    if rerollsLeft <= 0 then
        showMessage("Você não tem mais rerolls disponíveis!", "red")
        return
    end

    -- Verificar quais tasks estão locked
    local lockedIds = {}
    for i, task in ipairs(currentTasks) do
        if lockedTasks[i] then
            table.insert(lockedIds, task.monsterId)
        end
    end

    sendOpcode({
        action = "rerollTasks",
        category = selectedTab,
        lockedIds = lockedIds
    })
end

function onTaskStarted(data)
    showMessage(data.message or "Task iniciada!", "green")
    requestTaskData()
end

function onTaskFinished(data)
    showMessage(data.message or "Task concluída!", "green")
    requestTaskData()
end

function onTaskCancelled(data)
    showMessage(data.message or "Task cancelada!", "yellow")
    requestTaskData()
end

function onRerollResult(data)
    if data.success then
        rerollsLeft = data.rerolls or (rerollsLeft - 1)
        currentTasks = data.tasks or currentTasks
        updateRerollCount()
        updateCards()
        showMessage("Tasks reroladas com sucesso!", "green")
    else
        showMessage(data.message or "Erro ao rerollar tasks!", "red")
    end
end

-- ========================================
-- JANELA
-- ========================================
function toggleWindow()
    if not g_game.isOnline() then
        return
    end

    if not taskWindow then
        createWindow()
    end

    if taskWindow then
        if taskWindow:isVisible() then
            taskWindow:setVisible(false)
        else
            taskWindow:setVisible(true)
            taskWindow:raise()
            taskWindow:focus()
            requestTaskData()
        end
    end
end

function showMessage(text, color)
    if not taskWindow then return end

    local actionPanel = taskWindow:getChildById('actionPanel')
    if not actionPanel then return end

    local msgLabel = actionPanel:getChildById('messageLabel')
    if msgLabel then
        msgLabel:setText(text)
        msgLabel:setColor(color or "white")

        removeEvent(msgLabel.clearEvent)
        msgLabel.clearEvent = scheduleEvent(function()
            if msgLabel and not msgLabel:isDestroyed() then
                msgLabel:setText("")
            end
        end, 5000)
    end
end
