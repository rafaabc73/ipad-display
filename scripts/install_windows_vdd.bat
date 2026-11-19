@echo off
title iPad Display Pro - Instalador de Monitor Virtual para Windows
echo =====================================================================
echo    iPad Display Pro v2.0 - Monitor Virtual para Windows 10 / 11
echo =====================================================================
echo.
echo Para usar o modo "Segunda Tela Estendida" no Windows, o Windows
echo precisa de um driver de monitor virtual (o modo "Espelhar Tela"
echo ja funciona imediatamente sem instalar nada).
echo.
echo Driver recomendado (gratuito, open-source e assinado):
echo   Virtual Display Driver (MikeTheTech / MTT-Virtual-Display-Driver)
echo   https://github.com/VirtualDrivers/Virtual-Display-Driver/releases
echo.
echo Para conexao via cabo USB no Windows com o App Nativo do iPad,
echo certifique-se tambem de ter o "Apple Devices" ou "iTunes" instalado
echo (ele fornece o servico Apple Mobile Device Support / usbmuxd).
echo.
echo Pressione qualquer tecla para abrir a pagina oficial de download...
pause >nul
start https://github.com/VirtualDrivers/Virtual-Display-Driver/releases
