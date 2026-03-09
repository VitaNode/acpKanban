import sys
import requests
import json

if len(sys.argv) < 3:
    print("Usage: python3 exchange_code.py <code> <verifier>")
    sys.exit(1)

code = sys.argv[1]
verifier = sys.argv[2]

client_id = "32555940559.apps.googleusercontent.com"
token_url = "https://oauth2.googleapis.com/token"

data = {
    "grant_type": "authorization_code",
    "code": code,
    "client_id": client_id,
    "redirect_uri": "https://sdk.cloud.google.com/authcode.html",
    "code_verifier": verifier
}

response = requests.post(token_url, data=data)

if response.status_code == 200:
    tokens = response.json()
    # Save tokens to a persistent location
    with open("workspace/gws_tokens.json", "w") as f:
        json.dump(tokens, f)
    print("TOKEN_SUCCESS")
    print(json.dumps(tokens, indent=2))
else:
    print(f"TOKEN_FAILED: {response.status_code}")
    print(response.text)
