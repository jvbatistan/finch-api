class AddUserSessionVersion < ActiveRecord::Migration[6.1]
  def up
    add_column :users, :session_version, :bigint, default: 0, null: false

    execute <<~SQL
      CREATE FUNCTION finch_revoke_user_sessions_on_deactivation()
      RETURNS trigger AS $$
      BEGIN
        IF OLD.active IS TRUE AND NEW.active IS FALSE THEN
          NEW.session_version := OLD.session_version + 1;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    execute <<~SQL
      CREATE TRIGGER finch_revoke_user_sessions_on_deactivation
      BEFORE UPDATE OF active ON users
      FOR EACH ROW
      EXECUTE FUNCTION finch_revoke_user_sessions_on_deactivation();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER finch_revoke_user_sessions_on_deactivation ON users;
    SQL

    execute <<~SQL
      DROP FUNCTION finch_revoke_user_sessions_on_deactivation();
    SQL

    remove_column :users, :session_version
  end
end
