-- Simple test script for REFramework
-- Open the game, press Insert, then Reset Scripts

log.info("[test_script.lua] - Mod loading test initiated!")

re.on_draw_ui(function()
    imgui.text("Hello! REFramework Lua scripting works!")
end)