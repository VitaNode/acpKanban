from src.persistence.database import KanbanDB
import os

def test_progress_logic():
    db = KanbanDB("kanban.db")
    
    # 1. Get a project
    projects = db.get_projects()
    if not projects:
        print("No projects found to test.")
        return
    pid = projects[0]['id']
    print(f"Testing with project: {pid}")
    
    # 2. Test progress stats retrieval
    stats = db.get_project_progress(pid)
    print(f"Retrieved {len(stats)} milestones.")
    if stats:
        m = stats[0]
        print(f"Milestone: {m['title']}, Progress: {m['progress']}%")
        if m['features']:
            f = m['features'][0]
            print(f"  Feature: {f['title']}, Progress: {f['progress']}%")
            print(f"  Counts: {f['counts']}")
    
    # 3. Test plan_status sync
    # Create a dummy card in the first column
    cols = db.get_columns(pid)
    if cols:
        col_id = cols[0]['id']
        # Use default feature if available
        feature_id = stats[0]['features'][0]['id'] if stats and stats[0]['features'] else None
        
        cid = db.create_card(col_id, "Test Sync Card", feature_id=feature_id)
        card = db.get_card(cid)
        print(f"Initial plan_status: {card['plan_status']}") # Should be 'plan'
        
        db.update_card_session_id(cid, "fake-session-id")
        card = db.get_card(cid)
        print(f"After setting session_id: {card['plan_status']}") # Should be 'active'
        
        db.update_card_session_id(cid, None)
        card = db.get_card(cid)
        print(f"After clearing session_id: {card['plan_status']}") # Should be 'plan'
        
        db.complete_card(cid)
        card = db.get_card(cid)
        print(f"After complete_card: {card['plan_status']}") # Should be 'completed'
        
        # Cleanup
        db.delete_card(cid)
        print("Test card deleted.")

if __name__ == "__main__":
    test_progress_logic()
