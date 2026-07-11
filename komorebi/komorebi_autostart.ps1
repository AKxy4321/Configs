# Start the window manager and hotkey engine
komorebic start --whkd

# Pause briefly for layout engine preparation
Start-Sleep -Seconds 1

# Launch the focus-on-hover tool without creating a window
Start-Process -FilePath "masir" -WindowStyle Hidden