import GRDB

/// Split camera days. Additive: existing assets keep a NULL slot, which means the main day folder.
extension Schema {
    static func createDayPlace(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE asset ADD COLUMN place_slot TEXT;

        CREATE TABLE day_place (
            day TEXT NOT NULL,
            slot TEXT NOT NULL,
            place_key TEXT,
            place_name TEXT,
            PRIMARY KEY (day, slot)
        );

        CREATE INDEX move_job_subject ON move_job(destination_id, subject);
        """)
    }
}
