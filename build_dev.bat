tools\sokol-shdc.exe -i shaders/shader.glsl -o shaders/shader.odin -l hlsl5 -f sokol_odin
@if %ERRORLEVEL% NEQ 0 exit /b 1

REM Build with debug and DEBUG=true, with custom output name
odin build . -debug -define:DEBUG=true -out:OdinProject-DevBuild.exe
@if %ERRORLEVEL% NEQ 0 exit /b 1

@if "%1" == "run" (
    OdinProject-DevBuild.exe
)