# SANCIM App

This is a mobile app for the Smart Assistive Navigation Cane with Integrated Mobile Monitoring for Visually Impaired  
Individual (SANCIM) project. This current version allows users to:

1.) **Stream as Server** - serves as the exteral device attached to the cane. This will be connected to the sensor  
via bluetooth module (will be implemented in the next update.  
2.) **Connect as Client** - serves as the monitoring device which receives images and notifcations from the server  
device.

This current version uses WebSocket Communication which enables a **direct server-client** connection.  Additionally, there is no
need for mobile data for this. This may also appear laggy as it only has 5 fps due to the current function.  The developer
will look for other ways to better implement this program.

# How to Use SANCIM app

1.) Open the app and allows all required permissions.  
2.) Tap 'Stream as Server' and note the IP address.  
3.) For the other device (for monitoring), tap 'Connect as Client' and fill out the  
needed information.  
4.) Enjoy!
