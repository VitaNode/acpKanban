import requests
import time

BASE_URL = "http://localhost:8001/api"


def test_roadmap_delete_behavior():
    created_project_id = None
    created_card_id = None
    created_feature_id = None
    created_milestone_id = None

    try:
        # 1. Create a project
        print("[*] Creating project...")
        project_resp = requests.post(f"{BASE_URL}/projects", json={"name": "Test Roadmap Delete Project"})
        assert project_resp.status_code == 201, f"Failed to create project: {project_resp.text}"
        project = project_resp.json()
        created_project_id = project["id"]
        print(f"[+] Project created: {created_project_id}")

        # 2. Verify default milestone/feature titles are English
        print("[*] Fetching milestones...")
        progress_resp = requests.get(
            f"{BASE_URL}/projects/{created_project_id}/progress",
            params={"depth": 2}
        )
        assert progress_resp.status_code == 200, f"Failed to get progress: {progress_resp.text}"
        milestones = progress_resp.json()
        assert len(milestones) > 0, "Expected at least one default milestone"
        default_milestone = milestones[0]
        assert default_milestone["title"] == "Uncategorized", \
            f"Expected milestone title 'Uncategorized', got '{default_milestone['title']}'"
        assert len(default_milestone["features"]) > 0, "Expected at least one default feature"
        default_feature = default_milestone["features"][0]
        assert default_feature["title"] == "General", \
            f"Expected feature title 'General', got '{default_feature['title']}'"
        created_milestone_id = default_milestone["id"]
        created_feature_id = default_feature["id"]
        print(f"[+] Default milestone: '{default_milestone['title']}' ({created_milestone_id})")
        print(f"[+] Default feature: '{default_feature['title']}' ({created_feature_id})")

        # 3. Create a card with the feature
        print("[*] Getting columns...")
        cols_resp = requests.get(f"{BASE_URL}/projects/{created_project_id}/columns")
        assert cols_resp.status_code == 200
        columns = cols_resp.json()
        assert len(columns) > 0, "Expected at least one column"
        todo_col_id = columns[0]["id"]

        print("[*] Creating card with feature_id...")
        card_resp = requests.post(f"{BASE_URL}/cards", json={
            "column_id": todo_col_id,
            "title": "Test Roadmap Delete Card",
            "description": "Card to verify unlink behavior on feature/milestone delete",
            "feature_id": created_feature_id,
        })
        assert card_resp.status_code == 201, f"Failed to create card: {card_resp.text}"
        card = card_resp.json()
        created_card_id = card["id"]
        assert card.get("feature_id") == created_feature_id, \
            f"Expected feature_id={created_feature_id}, got {card.get('feature_id')}"
        print(f"[+] Card created: {created_card_id} with feature_id={created_feature_id}")

        # 4. Delete the feature and verify card feature_id is NULL
        print("[*] Deleting feature...")
        del_feature_resp = requests.delete(
            f"{BASE_URL}/features/{created_feature_id}",
        )
        assert del_feature_resp.status_code == 200, \
            f"Failed to delete feature: {del_feature_resp.text}"
        print(f"[+] Feature deleted: {created_feature_id}")

        print("[*] Verifying card feature_id is NULL after feature delete...")
        card_resp = requests.get(f"{BASE_URL}/cards/{created_card_id}")
        assert card_resp.status_code == 200, f"Failed to fetch card: {card_resp.text}"
        card = card_resp.json()
        assert card.get("feature_id") is None, \
            f"Expected feature_id to be NULL after feature delete, got '{card.get('feature_id')}'"
        assert card.get("deleted_at") is None, \
            "Card should NOT be soft-deleted when its feature is deleted"
        print(f"[+] Card {created_card_id} feature_id is NULL, card still exists. OK")

        # 5. Create another card, then delete the milestone
        # First create a new feature under the same milestone
        print("[*] Creating a new feature for milestone delete test...")
        create_feature_resp = requests.post(
            f"{BASE_URL}/milestones/{created_milestone_id}/features",
            json={
                "title": "Test Feature for Milestone Delete",
            },
        )
        assert create_feature_resp.status_code == 201, \
            f"Failed to create feature: {create_feature_resp.text}"
        new_feature_id = create_feature_resp.json()["id"]
        print(f"[+] New feature created: {new_feature_id}")

        # Create a card with this new feature
        print("[*] Creating second card with new feature...")
        card2_resp = requests.post(f"{BASE_URL}/cards", json={
            "column_id": todo_col_id,
            "title": "Test Milestone Delete Card",
            "feature_id": new_feature_id,
        })
        assert card2_resp.status_code == 201, f"Failed to create card: {card2_resp.text}"
        card2 = card2_resp.json()
        card2_id = card2["id"]
        assert card2.get("feature_id") == new_feature_id
        print(f"[+] Second card created: {card2_id} with feature_id={new_feature_id}")

        # Delete the milestone
        print("[*] Deleting milestone...")
        del_milestone_resp = requests.delete(
            f"{BASE_URL}/milestones/{created_milestone_id}",
        )
        assert del_milestone_resp.status_code == 200, \
            f"Failed to delete milestone: {del_milestone_resp.text}"
        print(f"[+] Milestone deleted: {created_milestone_id}")

        # Verify both cards still exist with feature_id=NULL
        print("[*] Verifying both cards after milestone delete...")
        for cid in [created_card_id, card2_id]:
            card_resp = requests.get(f"{BASE_URL}/cards/{cid}")
            assert card_resp.status_code == 200, f"Failed to fetch card {cid}: {card_resp.text}"
            card = card_resp.json()
            assert card.get("feature_id") is None, \
                f"Card {cid}: expected feature_id=NULL after milestone delete, got '{card.get('feature_id')}'"
            assert card.get("deleted_at") is None, \
                f"Card {cid} should NOT be soft-deleted when its milestone is deleted"
            print(f"[+] Card {cid}: feature_id=NULL, deleted_at=NULL. OK")

        print("\n=== ALL TESTS PASSED ===")

    finally:
        # Cleanup
        if created_card_id:
            requests.delete(f"{BASE_URL}/cards/{created_card_id}")
        if created_project_id:
            try:
                requests.delete(f"{BASE_URL}/projects/{created_project_id}")
                print(f"[*] Cleaned up project {created_project_id}")
            except Exception:
                pass
