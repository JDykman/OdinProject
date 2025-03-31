tools\sokol-shdc.exe -i shaders/shader.glsl -o shaders/shader.odin -l hlsl5 -f sokol_odin
@if %ERRORLEVEL% NEQ 0 exit /b 1

REM Build with release optimizations and DEBUG=false, with custom output name
odin build . -o:speed -no-bounds-check -define:DEBUG=false -out:builds/OdinProject-Release.exe
@if %ERRORLEVEL% NEQ 0 exit /b 1

@if "%1" == "run" (
    cd builds/
    OdinProject-Release.exe
)