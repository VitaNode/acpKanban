import sqlite3

conn = sqlite3.connect('kanban.db')
cursor = conn.execute("""
SELECT * FROM (
    SELECT id, seq_id FROM card_sessions
    WHERE card_id = ? AND (? IS NULL OR seq_id < ?)
    ORDER BY seq_id DESC, id DESC
    LIMIT ?
) ORDER BY seq_id ASC, id ASC
""", ['ef6c979e', None, None, 200])
rows = cursor.fetchall()
print(f"Total rows fetched: {len(rows)}")
if len(rows) > 0:
    print(f"First row: {rows[0]}")
    print(f"Last row: {rows[-1]}")
