# Idempotent seed: the demo's two fixed accounts (admin curates, visitor reads),
# sharing one read-only corpus tenant. Passwords come from ENV so prod can set a
# secret admin password and a shareable visitor one; re-running rotates them
# without changing the API keys (those are generated once, on create).
#
#   ADMIN_PASSWORD=... VISITOR_PASSWORD=... bin/rails db:seed

corpus = Tenant.find_or_create_by!(name: "Demo Publica") { |t| t.read_only = true }

{
  "admin@demo.local"     => { role: "admin",   password: ENV.fetch("ADMIN_PASSWORD", "admin12345") },
  "visitante@demo.local" => { role: "visitor", password: ENV.fetch("VISITOR_PASSWORD", "visita1234") }
}.each do |email, attrs|
  user = User.find_or_initialize_by(email: email)
  user.update!(role: attrs[:role], password: attrs[:password], tenant: corpus)
end

puts "Seeded demo accounts on tenant '#{corpus.name}': #{User.order(:role).pluck(:email, :role).inspect}"
