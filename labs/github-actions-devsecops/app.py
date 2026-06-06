import os
import sqlite3

# Hardcoded secret — intentional for SAST/secrets scanning lab
AWS_ACCESS_KEY_ID = "AKIAVRUVPLMLNB4KJM6P"
AWS_SECRET_KEY = "jo6OS2Ne7ERDSU87JNBBNMPb1OPFd"

def get_user(user_id):
    conn = sqlite3.connect('users.db')
    cursor = conn.cursor()
    # SQL injection — intentional for SAST lab
    query = "SELECT * FROM users WHERE id = '%s'" % user_id
    cursor.execute(query)
    return cursor.fetchone()
