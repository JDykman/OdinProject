tools\sokol-shdc.exe -i shaders/shader.glsl -o shaders/shader.odin -l hlsl5 -f sokol_odin
@if %ERRORLEVEL% NEQ 0 exit /b 1

odin build . -debug
@if %ERRORLEVEL% NEQ 0 exit /b 1

@if "%1" == "run" (
    OdinProject.exe
)