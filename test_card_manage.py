import requests
import time
import json

BASE_URL = "http://localhost:8001/api"

def test_card_management():
    # 1. Create a project
    print("[*] Creating project...")
    project_resp = requests.post(f"{BASE_URL}/projects", json={"name": "Test Card Manage Project"})
    if project_resp.status_code != 201:
        print(f"[!] Failed to create project: {project_resp.text}")
        return
    project = project_resp.json()
    project_id = project["id"]
    print(f"[+] Project created: {project_id}")

    # 2. Get columns
    print("[*] Getting columns...")
    cols_resp = requests.get(f"{BASE_URL}/projects/{project_id}/columns")
    columns = cols_resp.json()
    todo_col_id = columns[0]["id"]
    print(f"[+] Todo column ID: {todo_col_id}")

    # 3. Create a card
    print("[*] Creating card...")
    card_resp = requests.post(f"{BASE_URL}/cards", json={
        "column_id": todo_col_id,
        "title": "Test Completion Card",
        "description": "This is a card to test completion and summary generation"
    })
    card = card_resp.json()
    card_id = card["id"]
    print(f"[+] Card created: {card_id}")

    # 4. Add some session messages
    print("[*] Adding session messages...")
    messages = [
        {"role": "user", "content": "Let's start the API development for card management."},
        {"role": "assistant", "content": "Sure, I'll start by defining the endpoints and database schema."},
        {"role": "assistant", "content": "I've added the `status` and `completed_at` columns to the `cards` table."},
        {"role": "user", "content": "Great, now implement the `complete` endpoint."},
        {"role": "assistant", "content": "Done! I've also added a background task to generate summaries."},
    ]
    for msg in messages:
        requests.post(f"{BASE_URL}/cards/{card_id}/session", json=msg)
    print("[+] Added 5 session messages")

    # 5. Complete the card
    print("[*] Completing card...")
    complete_resp = requests.patch(f"{BASE_URL}/cards/{card_id}/complete")
    if complete_resp.status_code == 200:
        updated_card = complete_resp.json()
        print(f"[+] Card status: {updated_card['status']}, completed_at: {updated_card['completed_at']}")
    else:
        print(f"[!] Failed to complete card: {complete_resp.text}")
        return

    # 6. Wait for background task
    print("[*] Waiting for background task (5s)...")
    time.sleep(5)

    # 7. Check summary
    print("[*] Checking summary...")
    summary_resp = requests.get(f"{BASE_URL}/cards/{card_id}/summary")
    if summary_resp.status_code == 200:
        summary_data = summary_resp.json()
        print(f"[+] Summary generated: {summary_data['summary'][:100]}...")
    else:
        print(f"[!] Summary not found yet (maybe LLM API failed or took too long)")

    # 8. Uncomplete the card
    print("[*] Uncompleting card...")
    uncomplete_resp = requests.patch(f"{BASE_URL}/cards/{card_id}/uncomplete")
    if uncomplete_resp.status_code == 200:
        updated_card = uncomplete_resp.json()
        print(f"[+] Card status: {updated_card['status']}, completed_at: {updated_card['completed_at']}")
    else:
        print(f"[!] Failed to uncomplete card: {uncomplete_resp.text}")

    # 9. Clean up (Optional)
    # requests.delete(f"{BASE_URL}/projects/{project_id}")

if __name__ == "__main__":
    test_card_management()
