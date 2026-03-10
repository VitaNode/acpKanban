import os
import base64
import hashlib
import secrets

def generate_pkce_pair():
    # Generate code_verifier (43-128 chars)
    # Using secrets to generate a safe random string
    code_verifier = secrets.token_urlsafe(64) # ~86 chars
    
    # Generate code_challenge
    sha256_hash = hashlib.sha256(code_verifier.encode('ascii')).digest()
    code_challenge = base64.urlsafe_b64encode(sha256_hash).decode('ascii').rstrip('=')
    
    return code_verifier, code_challenge

client_id = "764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com"
redirect_uri = "https://sdk.cloud.google.com/applicationdefaultauthcode.html"
scopes = [
    "openid",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/gmail.send",
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/contacts"
]

verifier, challenge = generate_pkce_pair()

# Save verifier for later exchange
with open("workspace/current_verifier.txt", "w") as f:
    f.write(verifier)

# Build URL
import urllib.parse
params = {
    "response_type": "code",
    "client_id": client_id,
    "redirect_uri": redirect_uri,
    "scope": " ".join(scopes),
    "code_challenge": challenge,
    "code_challenge_method": "S256",
    "access_type": "offline",
    "prompt": "consent",
    "login_hint": "fanthink.com@gmail.com"
}
auth_url = "https://accounts.google.com/o/oauth2/auth?" + urllib.parse.urlencode(params)

print(f"VERIFIER: {verifier}")
print(f"CHALLENGE: {challenge}")
print(f"URL: {auth_url}")
