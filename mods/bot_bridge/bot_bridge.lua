-- Bot Bridge - Comunica com bot Python externo
-- Lê comandos de arquivo e executa spells via g_game.talk()

local COMMANDS_FILE = "/bot_commands.json"
local checkEvent = nil
local processedCommands = {}
local enabled = true

function init()
    print("[BOT BRIDGE] Iniciando...")
    
    -- Inicia loop de verificação
    checkEvent = scheduleEvent(checkCommands, 100)
    
    print("[BOT BRIDGE] Ativo! Aguardando comandos...")
end

function terminate()
    if checkEvent then
        removeEvent(checkEvent)
        checkEvent = nil
    end
    print("[BOT BRIDGE] Finalizado!")
end

function checkCommands()
    if not enabled then
        checkEvent = scheduleEvent(checkCommands, 100)
        return
    end
    
    -- Verifica se está logado
    local player = g_game.getLocalPlayer()
    if not player then
        checkEvent = scheduleEvent(checkCommands, 500)
        return
    end
    
    -- Tenta ler arquivo de comandos
    local success, content = pcall(function()
        return g_resources.readFileContents(COMMANDS_FILE)
    end)
    
    if not success or not content or content == "" then
        checkEvent = scheduleEvent(checkCommands, 100)
        return
    end
    
    -- Parse JSON
    local ok, commands = pcall(json.decode, content)
    if not ok or type(commands) ~= "table" then
        checkEvent = scheduleEvent(checkCommands, 100)
        return
    end
    
    -- Processa comandos
    for _, cmd in ipairs(commands) do
        local cmdId = tostring(cmd.timestamp or 0)
        
        -- Só processa comandos novos
        if not processedCommands[cmdId] then
            processedCommands[cmdId] = true
            executeCommand(cmd)
        end
    end
    
    -- Limpa comandos antigos (mais de 10 segundos)
    local now = os.time()
    for id, _ in pairs(processedCommands) do
        local ts = tonumber(id) or 0
        if now - ts > 10 then
            processedCommands[id] = nil
        end
    end
    
    checkEvent = scheduleEvent(checkCommands, 100)
end

function executeCommand(cmd)
    local cmdType = cmd.type
    
    if cmdType == "say" or cmdType == "spell" then
        local text = cmd.text or cmd.spell or ""
        if text ~= "" then
            -- FALA A SPELL DIRETAMENTE!
            g_game.talk(text)
            print("[BOT BRIDGE] Spell: " .. text)
        end
        
    elseif cmdType == "ping" then
        print("[BOT BRIDGE] Ping OK!")
    end
end
