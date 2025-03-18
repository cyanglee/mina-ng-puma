require 'mina/bundler'
require 'mina/rails'

namespace :puma do
  set :web_server, :puma

  # Default debug level - can be overridden in mina command with DEBUG=1, 2, or 3
  set :debug_level,    -> { ENV['DEBUG'] ? ENV['DEBUG'].to_i : 0 }
  
  # Set the systemd service name for Puma
  set :puma_systemd_service, -> { ENV['PUMA_SERVICE'] || 'puma' }
  
  set :puma_role,      -> { fetch(:user) }
  set :puma_env,       -> { fetch(:rails_env, 'production') }
  set :puma_config,    -> { "#{fetch(:shared_path)}/config/puma.rb" }
  set :puma_socket,    -> { "#{fetch(:shared_path)}/tmp/sockets/puma.sock" }
  set :puma_state,     -> { "#{fetch(:shared_path)}/tmp/sockets/puma.state" }
  set :puma_pid,       -> { "#{fetch(:shared_path)}/tmp/pids/puma.pid" }
  set :puma_stdout,    -> { "#{fetch(:shared_path)}/log/puma.log" }
  set :puma_stderr,    -> { "#{fetch(:shared_path)}/log/puma.log" }

  # Helper method for debug output
  def debug_cmd(level, cmd)
    debug_level = fetch(:debug_level)
    if debug_level >= level
      debug_prefix = %{
        export PS4='+\${BASH_SOURCE}:\${LINENO}:\${FUNCNAME[0]}: '
        #{debug_level >= 3 ? 'set -xv' : (debug_level >= 2 ? 'set -x' : '')}
      }
      debug_suffix = %{
        #{debug_level >= 2 ? 'set +x' : ''}
      }
      return "#{debug_prefix}\n#{cmd}\n#{debug_suffix}"
    else
      return cmd
    end
  end

  # Helper to log environment information
  def log_environment_info
    cmd = %{
      echo "=== Environment Information ==="
      echo "Current shell: $SHELL"
      echo "Current user: $(whoami)"
      echo "Current directory: $(pwd)"
      echo "Path: $PATH"
      echo "Puma service: #{fetch(:puma_systemd_service)}"
      echo "===============================\n"
    }
    command cmd
  end

  desc 'Start puma'
  task :start do
    comment "Starting Puma via systemd..."
    command debug_cmd(1, %[
      echo "[DEBUG] Starting Puma via systemd service: #{fetch(:puma_systemd_service)}"
      if systemctl is-active --quiet #{fetch(:puma_systemd_service)}; then
        echo "Puma systemd service is already running"
      else
        sudo systemctl start #{fetch(:puma_systemd_service)}
        sleep 2
        if systemctl is-active --quiet #{fetch(:puma_systemd_service)}; then
          echo "Puma successfully started via systemd"
        else
          echo "[ERROR] Failed to start Puma via systemd. Status:"
          sudo systemctl status #{fetch(:puma_systemd_service)} --no-pager
          exit 1
        fi
      fi
    ])
  end

  desc 'Stop puma'
  task :stop do
    comment "Stopping Puma via systemd..."
    command debug_cmd(1, %[
      echo "[DEBUG] Stopping Puma via systemd service: #{fetch(:puma_systemd_service)}"
      if systemctl is-active --quiet #{fetch(:puma_systemd_service)}; then
        sudo systemctl stop #{fetch(:puma_systemd_service)}
        sleep 2
        if ! systemctl is-active --quiet #{fetch(:puma_systemd_service)}; then
          echo "Puma successfully stopped via systemd"
        else
          echo "[WARNING] Puma service is still running after stop command"
        fi
      else
        echo "Puma systemd service is not running"
      fi
    ])
  end

  desc 'Restart puma'
  task :restart do
    comment "Restart Puma via systemd..."
    command debug_cmd(1, %[
      echo "[DEBUG] Restarting Puma via systemd service: #{fetch(:puma_systemd_service)}"
      sudo systemctl restart #{fetch(:puma_systemd_service)}
      sleep 2
      if systemctl is-active --quiet #{fetch(:puma_systemd_service)}; then
        echo "Puma successfully restarted via systemd"
      else
        echo "[ERROR] Failed to restart Puma via systemd. Status:"
        sudo systemctl status #{fetch(:puma_systemd_service)} --no-pager
        exit 1
      fi
    ])
  end

  desc 'Restart puma (phased restart)'
  task :phased_restart do
    comment "Restart Puma -- phased mode via systemd..."
    command debug_cmd(1, %[
      echo "[DEBUG] Performing phased restart via systemd reload for: #{fetch(:puma_systemd_service)}"
      if systemctl is-active --quiet #{fetch(:puma_systemd_service)}; then
        # Check if the service supports reload
        if systemctl show -p CanReload #{fetch(:puma_systemd_service)} | grep -q "CanReload=yes"; then
          sudo systemctl reload #{fetch(:puma_systemd_service)}
          echo "Systemd reload command sent to Puma"
        else
          echo "[WARNING] Systemd service doesn't support reload, doing full restart instead"
          sudo systemctl restart #{fetch(:puma_systemd_service)}
        fi
        
        sleep 2
        if systemctl is-active --quiet #{fetch(:puma_systemd_service)}; then
          echo "Puma service active after phased restart attempt"
        else
          echo "[ERROR] Puma service not running after reload/restart"
          sudo systemctl status #{fetch(:puma_systemd_service)} --no-pager
          exit 1
        fi
      else
        echo "Puma systemd service is not running, starting it..."
        sudo systemctl start #{fetch(:puma_systemd_service)}
      fi
    ])
  end

  desc 'Restart puma (hard restart)'
  task :hard_restart do
    comment "Restart Puma -- hard mode via systemd..."
    command debug_cmd(1, %[
      echo "[DEBUG] Performing hard restart via systemd for: #{fetch(:puma_systemd_service)}"
      sudo systemctl stop #{fetch(:puma_systemd_service)}
      sleep 2
      sudo systemctl start #{fetch(:puma_systemd_service)}
      sleep 2
      if systemctl is-active --quiet #{fetch(:puma_systemd_service)}; then
        echo "Puma successfully hard-restarted via systemd"
      else
        echo "[ERROR] Failed to restart Puma via systemd. Status:"
        sudo systemctl status #{fetch(:puma_systemd_service)} --no-pager
        exit 1
      fi
    ])
  end

  desc 'Restart puma (smart restart)'
  task :smart_restart do
    comment "Restart Puma -- smart mode via systemd..."
    log_environment_info if fetch(:debug_level) >= 1
    
    command debug_cmd(1, %[
      echo "[DEBUG] Attempting smart restart via systemd for: #{fetch(:puma_systemd_service)}"
      
      # First check if service supports reload (for phased restart)
      if systemctl show -p CanReload #{fetch(:puma_systemd_service)} | grep -q "CanReload=yes"; then
        echo "Attempting phased restart via systemd reload..."
        sudo systemctl reload #{fetch(:puma_systemd_service)}
        
        # Check if service is still running after reload
        sleep 2
        if systemctl is-active --quiet #{fetch(:puma_systemd_service)}; then
          echo "Puma successfully reloaded via systemd"
          exit 0
        else
          echo "[WARNING] Reload failed, falling back to full restart"
        fi
      else
        echo "[INFO] Service doesn't support reload, using restart"
      fi
      
      # If we got here, either reload isn't supported or it failed
      echo "Performing full restart via systemd..."
      sudo systemctl restart #{fetch(:puma_systemd_service)}
      
      sleep 2
      if systemctl is-active --quiet #{fetch(:puma_systemd_service)}; then
        echo "Puma successfully restarted via systemd"
      else
        echo "[ERROR] Failed to restart Puma via systemd. Status:"
        sudo systemctl status #{fetch(:puma_systemd_service)} --no-pager
        exit 1
      fi
    ])
  end

  desc 'Get status of puma'
  task :status do
    comment "Puma status via systemd..."
    command %[
      echo "Checking Puma systemd service status: #{fetch(:puma_systemd_service)}"
      sudo systemctl status #{fetch(:puma_systemd_service)} --no-pager
    ]
  end
end
