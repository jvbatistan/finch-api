Warden::Manager.after_set_user(scope: :user, except: :fetch) do |user, auth, options|
  if user.active?
    auth.session(options[:scope])['session_version'] = user.session_version
  else
    auth.logout(options[:scope])
  end
end

Warden::Manager.after_fetch(scope: :user) do |user, auth, options|
  stored_version = auth.session(options[:scope])['session_version']
  auth.logout(options[:scope]) unless user.active? && stored_version == user.session_version
end
