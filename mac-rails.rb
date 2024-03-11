# frozen_string_literal: true

source_paths.unshift(File.dirname(__FILE__) + "/templates")

tailwindcss = options[:css] == "tailwind"
sqlite = options[:database] == "sqlite3"
postgresql = options[:database] == "postgresql"

ruby_version = RUBY_VERSION
rails_version = Rails::VERSION::STRING

port = ask "Default port for your app? (3000)"
port = port&.strip! || 3000

puts "Crating a Profile.dev file"
create_file "Procfile.dev" do
  tailwindcss_process = "css: bin/rails tailwindcss:watch"
  <<~EOF
    web: bin/rails server -p #{port}
    #{tailwindcss_process if tailwindcss}
  EOF
end

puts "Setting up Overmind"
create_file ".overmind.env" do
  <<~EOF
    OVERMIND_PROCFILE=Procfile.dev
  EOF
end

puts "Adding gems"
gem_group :development do
  gem "brakeman"
  gem "bundle-audit"
  gem "letter_opener"
  gem "standard"
end

gem "action_policy"
gem "litestack", "~> 0.4.2" if sqlite
gem "lograge"
gem "meta-tags"
gem "mission_control-jobs"
gem "rails-i18n"
gem "rack-attack"
gem "solid_queue"

gem_group :production do
  gem "aws-sdk-s3", require: false
end

puts "Application configuration"
append_to_file(".gitignore", %(\n/config/database.yml\n))

create_file ".standard.yml" do
  <<~EOF
    fix: false              # default: false
    parallel: true          # default: false
    format: progress        # default: Standard::Formatter
    ruby_version: 3.3.0     # default: RUBY_VERSION
    default_ignores: false  # default: true
    ignore:                 # default: []
      - 'node_modules/**/*'
      - 'db/migrate/**/*'
      - 'db/schema.rb'
      - 'bin/**/*'
      - 'Gemfile'
      - 'config/environments/**/*'
      - 'config/application.rb'
      - 'config/boot.rb'
      - 'config/puma.rb'
  EOF
end

create_file ".solargraph.yml" do
  <<~EOF
    include:
      - "**/*.rb"
    exclude:
      - spec/**/*
      - test/**/*
      - vendor/**/*
      - ".bundle/**/*"
    require:
      - actioncable
      - actionmailer
      - actionpack
      - actionview
      - activejob
      - activemodel
      - activerecord
      - activestorage
      - activesupport
    plugins:
      - solargraph-rails
    max_files: 5000
  EOF
end

create_file ".rubocop.yml" do
  <<~EOF
    require: standard

    inherit_gem:
      standard: config/base.yml
  EOF
end

remove_file "bin/setup"
create_file "bin/setup" do
  <<~EOF
    #!/usr/bin/env ruby
    require "fileutils"
    # path to your application root.
    APP_ROOT = File.expand_path('..', __dir__)
    def system!(*args)
      system(*args) || abort("\\n== Command \#{args} failed ==")
    end
    FileUtils.chdir APP_ROOT do
      # This script is a way to set up or update your development environment automatically.
      # This script is idempotent, so that you can run it at any time and get an expectable outcome.
      # Add necessary setup steps to this file.
      puts '== Installing Ruby dependencies =='
      system! 'gem install bundler --conservative'
      system('bundle check') || system!('bundle install')
      puts "\\n== Copying sample files =="
      unless File.exist?('config/database.yml')
        FileUtils.cp 'config/database.yml.sample', 'config/database.yml'
      end
      puts "\\n== Preparing database =="
      system! 'bin/rails db:prepare'
      puts "\\n== Removing old logs and tempfiles =="
      system! 'bin/rails log:clear tmp:clear'
      puts "\\n== Restarting application server =="
      if File.exist?('.overmind.sock')
        system! 'overmind restart'
      end
    end
  EOF
end
run "chmod +x bin/setup"

create_file "bin/ci" do
  <<~EOF
    # bin/ci
    #!/usr/bin/env bash
    set -e
    echo "Running Unit Tests"
    bin/rails test
    echo "Running System Tests"
    bin/rails test:system
    echo "Linting Ruby code with StandardRb."
    echo "It will not autofix issues."
    bundle exec standardrb
    echo "Analyzing code for security vulnerabilities."
    echo "Output will be in tmp/brakeman.html, which"
    echo "can be opened in your browser."
    bundle exec brakeman -q -o tmp/brakeman.html
    echo "Analyzing Ruby gems for"
    echo "security vulnerabilities"
    bundle exec bundle audit check --update
    echo "Analyzing Node modules"
    echo "for security vulnerabilities"
  EOF
end
run "chmod +x bin/ci"

initializer("generators.rb") do
  <<~EOF
    Rails.application.config.generators do |g|
      g.stylesheets false
    end
  EOF
end

initializer("lograge.rb") do
  <<~EOF
    Rails.application.configure do
      config.lograge.enabled = !Rails.env.development? || ENV["LOGRAGE_IN_DEVELOPMENT"] == "true"
    end
  EOF
end

initializer("rack_attack.rb") do
  <<~EOF
    Rack::Attack.enabled = !Rails.env.test?

    # Throttle requests from a single IP to 5 requests per second
    Rack::Attack.throttle('req/ip', limit: 5, period: 1.second) do |req|
      req.ip
    end

    # Rack::Attack.throttle('limit logins per email', limit: 5, period: 1.minute) do |req|
    #   if req.path == '/login' && req.post?
    #     req.params['email']
    #   end
    # end

    # Rack::Attack.blocklist("block script kidz") do |req|
    #   CGI.unescape(req.query_string) =~ %r{/etc/passwd} ||
    #   req.path.include?("/etc/passwd") ||
    #   req.path.include?("wp-admin") ||
    #   req.path.include?("wp-login")
    # end
  EOF
end

environment(nil, env: "development") do
  <<~EOF
    # Letter opener configuration
    config.default_url_options = { host: "localhost:#{port}" }
    config.action_mailer.delivery_method = :letter_opener
    config.action_mailer.perform_deliveries = true
  EOF
end

environment(nil, env: "production") do
  <<~EOF
    # Update this value with real domain name
    config.default_url_options = { host: ENV.fetch("APPLICATION_HOST") }
  EOF
end
insert_into_file "config/application.rb", after: '    # config.time_zone = "Central Time (US & Canada)"' do
  "\n    # Configure your locales.\n    # config.i18n.available_locales = :es\n    # config.i18n.default_locale = :es\n"
end

insert_into_file "config/application.rb", after: '    # config.eager_load_paths << Rails.root.join("extras")' do
  "\n    # Configure a proxy for Active Storage if need it. Also, don't forget to set public: true in config/storage.yml file.\n    # config.active_storage.resolve_model_to_route = :rails_storage_proxy\n"
end

insert_into_file "config/application.rb", before: "  end" do
  <<EOF
    config.action_view.field_error_proc = proc { |html_tag, instance| html_tag.html_safe }

    unless Rails.env.test?
      config.active_job.queue_adapter = :solid_queue
    end
EOF
end

insert_into_file "config/application.rb", after: "  class Application < Rails::Application" do
  "\n    config.middleware.use Rack::Attack"
end

after_bundle do
  puts "Run generators"
  generate "litestack:install" if sqlite

  generate "action_policy:install"

  rails_command "action_text:install"
  rails_command "db:migrate"

  rails_command "active_storage:install"
  rails_command "db:migrate"

  rails_command "solid_queue:install:migrations"
  if sqlite
    copy_file "database.yml.example", "config/database.yml", force: true
    run("mkdir db/queue_migrate && mv db/migrate/*solid_queue*.rb db/queue_migrate")
    rails_command "db:migrate:queue"

    insert_into_file "config/application.rb", after: "config.active_job.queue_adapter = :solid_queue" do
      "\n      config.solid_queue.connects_to = { database: { writing: :queue, reading: :queue } }"
    end
  else
    rails_command "db:migrate"
  end

  copy_file "solid_queue.yml.example", "config/solid_queue.yml"
  insert_into_file "Procfile.dev", after: /\z/ do
    "solid_queue: bin/rails solid_queue:start"
  end

  insert_into_file "config/routes.rb", before: "end" do
    "  mount MissionControl::Jobs::Engine, at: \"/jobs\"\n"
  end

  generate "meta_tags:install"

  insert_into_file "config/importmap.rb", before: 'pin "@rails/actiontext", to: "actiontext.esm.js"' do
    "pin \"@rails/activestorage\", to: \"activestorage.esm.js\"\n"
  end

  insert_into_file "app/javascript/application.js", before: 'import "@rails/actiontext"' do
    "import * as ActiveStorage from \"@rails/activestorage\"\nActiveStorage.start()\n"
  end

  insert_into_file "app/views/layouts/application.html.erb", before: "</head>" do
    "\n  <%= turbo_refreshes_with method: :morph, scroll: :preserve %>\n    <%= yield :head %>\n"
  end

  insert_into_file "app/views/layouts/application.html.erb", after: "<head>" do
    "\n    <%= display_meta_tags site: \"My Rails application\" %>"
  end

  inside("config") do
    run("cp database.yml database.yml.example")
  end

  if tailwindcss
    insert_into_file "config/tailwind.config.js", before: "      fontFamily: {" do
      <<~EOF
        textColor: {
          skin: {
            inverted: 'rgb(var(--color-inverted) / <alpha-value>)',
            accented: 'rgb(var(--color-accented) / <alpha-value>)',
            'accented-hover': 'rgb(var(--color-accented-hover) / <alpha-value>)',
            base: 'rgb(var(--color-base) / <alpha-value>)',
            muted: 'rgb(var(--color-muted) / <alpha-value>)',
            dimmed: 'rgb(var(--color-dimmed) / <alpha-value>)',
            error: 'rgb(var(--color-error) / <alpha-value>)',
            alternate: 'rgb(var(--color-alternate) / <alpha-value>)',
          }
        },
        backgroundColor: {
          skin: {
            'button-accented': 'rgb(var(--color-accented) / <alpha-value>)',
            'button-accented-hover': 'rgb(var(--color-accented-hover) / <alpha-value>)',
            'button-inverted': 'rgb(var(--color-inverted) / <alpha-value>)',
            'button-inverted-hover': 'rgb(var(--color-inverted-hover) / <alpha-value>)',
            'button-caution': 'rgb(var(--color-error) / <alpha-value>)',
            'button-caution-hover': 'rgb(var(--color-error-hover) / <alpha-value>)',
            muted: 'rgb(var(--color-muted) / <alpha-value>)',
            dimmed: 'rgb(var(--color-dimmed) / <alpha-value>)',
            accented: 'rgb(var(--color-accented) / <alpha-value>)',
            'accented-hover': 'rgb(var(--color-accented-hover) / <alpha-value>)',
            alternate: 'rgb(var(--color-alternate) / <alpha-value>)',
          }
        },
        ringColor: {
          skin: {
            accented: 'rgb(var(--color-border-accented) / <alpha-value>)',
            inverted: 'rgb(var(--color-inverted) / <alpha-value>)',
            error: 'rgb(var(--color-error) / <alpha-value>)',
          }
        },
        borderColor: {
          skin: {
            base: 'rgb(var(--color-border-base) / <alpha-value>)',
            error: 'rgb(var(--color-error) / <alpha-value>)',
            accented: 'rgb(var(--color-border-accented) / <alpha-value>)',
          }
        },
        textDecorationColor: {
          skin: {
            accented: 'rgb(var(--color-border-accented) / <alpha-value>)'
          }
        },
      EOF
    end

    create_file "app/assets/stylesheets/config.css" do
      <<~EOF
        :root {
          --color-base: 15 23 42;
          --color-accented: 244 63 94;
          --color-accented-hover: 190 18 60;
          --color-inverted: 255 255 255;
          --color-muted: 55 65 81;
          --color-dimmed: 75 85 99;
          --color-error: 220 38 38;
          --color-error-hover: 185 28 28;
          --color-alternate: 249 115 22;
          --color-alternate-1: 230 242 251;
          --color-alternate-2: 2 63 109;

          --color-border-base: 209 213 219;
          --color-border-accented: 244 63 94;
        }

        body {
          @apply font-sans antialiased;
        }
      EOF
    end

    insert_into_file "app/assets/stylesheets/application.tailwind.css", after: "@tailwind base;" do
      "\n@import \"config.css\";"
    end

    insert_into_file "app/assets/stylesheets/application.tailwind.css", before: "@import 'actiontext.css';" do
      "@import \"trix.css\";\n"
    end

    copy_file "trix.css", "app/assets/stylesheets/trix.css"

    gsub_file "app/views/layouts/application.html.erb", /container/, "max-w-2xl"
    gsub_file "app/assets/stylesheets/application.tailwind.css", /@tailwind base;/, "@import \"tailwindcss/base\";"
    gsub_file "app/assets/stylesheets/application.tailwind.css", /@tailwind components;/, "@import \"tailwindcss/components\";"
    gsub_file "app/assets/stylesheets/application.tailwind.css", /@tailwind utilities;/, "@import \"tailwindcss/utilities\";"
  end
end

erb_readme_template = File.read(File.expand_path("templates/README.md.erb", __dir__))
rendered_content = ERB.new(erb_readme_template).result(binding)

create_file "README.md", rendered_content, force: true

copy_file "home_controller.rb", "app/controllers/home_controller.rb"
run("mkdir app/views/home")
copy_file "index.html.erb", "app/views/home/index.html.erb"

gsub_file "config/routes.rb", /# root "posts#index"/, "root \"home#index\""
