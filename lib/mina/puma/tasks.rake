require 'mina/bundler'
require 'mina/rails'

namespace :puma do
  set :web_server, :puma

  # Default debug level - can be overridden in mina command with DEBUG=1, 2, or 3
  set :debug_level,    -> { ENV['DEBUG'] ? ENV['DEBUG'].to_i : 0 }
  
  set :puma_role,      -> { fetch(:user) }
  set :puma_env,       -> { fetch(:rails_env, 'production') }
  set :puma_config,    -> { "#{fetch(:shared_path)}/config/puma.rb" }
  set :puma_socket,    -> { "#{fetch(:shared_path)}/tmp/sockets/puma.sock" }
  set :puma_state,     -> { "#{fetch(:shared_path)}/tmp/sockets/puma.state" }
  set :puma_pid,       -> { "#{fetch(:shared_path)}/tmp/pids/puma.pid" }
  set :puma_stdout,    -> { "#{fetch(:shared_path)}/log/puma.log" }
  set :puma_stderr,    -> { "#{fetch(:shared_path)}/log/puma.log" }
  set :puma_cmd,       -> { "#{fetch(:bundle_prefix)} puma" }
  set :pumactl_cmd,    -> { "#{fetch(:bundle_prefix)} pumactl" }
  set :pumactl_socket, -> { "#{fetch(:shared_path)}/tmp/sockets/pumactl.sock" }
  set :puma_root_path, -> { fetch(:current_path) }

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
      echo "===============================\n"
    }
    command cmd
  end

  desc 'Start puma'
  task :start do
    puma_port_option = "-p #{fetch(:puma_port)}" if set?(:puma_port)

    comment "Starting Puma..."
    command debug_cmd(1, %[
      # Log key information
      echo "[DEBUG] Current directory: $(pwd)"
      echo "[DEBUG] Checking for existing PID file: #{fetch(:puma_pid)}"
      
      if [ -e "#{fetch(:puma_pid)}"  ] && kill -0 "$(cat #{fetch(:puma_pid)})" 2> /dev/null; then
        echo 'Puma is already running!';
      else
        if [ -e "#{fetch(:puma_config)}" ]; then
          echo "[DEBUG] Using config file: #{fetch(:puma_config)}"
          cd #{fetch(:puma_root_path)} && #{fetch(:puma_cmd)} -q -e #{fetch(:puma_env)} -C #{fetch(:puma_config)}
          echo "[DEBUG] Puma start exit code: $?"
        else
          echo "[DEBUG] Config file not found, using command line options"
          cd #{fetch(:puma_root_path)} && #{fetch(:puma_cmd)} -q -e #{fetch(:puma_env)} -b "unix://#{fetch(:puma_socket)}" #{puma_port_option} -S #{fetch(:puma_state)} --pidfile #{fetch(:puma_pid)} --control 'unix://#{fetch(:pumactl_socket)}' --redirect-stdout "#{fetch(:puma_stdout)}" --redirect-stderr "#{fetch(:puma_stderr)}"
          echo "[DEBUG] Puma start exit code: $?"
        fi
      fi
    ])
  end

  desc 'Stop puma'
  task :stop do
    comment "Stopping Puma..."
    pumactl_command 'stop'
    command %[rm -f '#{fetch(:pumactl_socket)}']
  end

  desc 'Restart puma'
  task :restart do
    comment "Restart Puma...."
    pumactl_restart_command 'restart'
  end

  desc 'Restart puma (phased restart)'
  task :phased_restart do
    comment "Restart Puma -- phased mode..."
    pumactl_restart_command 'phased-restart'
    wait_phased_restart_successful_command
  end

  desc 'Restart puma (hard restart)'
  task :hard_restart do
    comment "Restart Puma -- hard mode..."
    invoke 'puma:stop'
    wait_quit_or_force_quit_command
    invoke 'puma:start'
  end

  desc 'Restart puma (smart restart)'
  task :smart_restart do
    comment "Restart Puma -- smart mode..."
    log_environment_info if fetch(:debug_level) >= 1
    comment "Trying phased restart..."
    pumactl_restart_command 'phased-restart'
    hard_restart_script = %{
      echo "Phased-restart have failed, using hard-restart mode instead..." \n
    }
    # TODO: refactor it when we have better method
    # hacking in mina commands.process to get hard_restart script
    on :puma_smart_restart_tmp do
      invoke 'puma:hard_restart'
      hard_restart_script += commands.process
    end
    wait_phased_restart_successful_command(60, hard_restart_script)
  end

  desc 'Get status of puma'
  task :status do
    comment "Puma status..."
    pumactl_command 'status'
  end

  def pumactl_command(command)
    cmd =  %{
      if [ -e "#{fetch(:puma_pid)}"  ]; then
        echo "[DEBUG] PID file exists: #{fetch(:puma_pid)}"
        if kill -0 "$(cat #{fetch(:puma_pid)})" 2> /dev/null; then
          echo "[DEBUG] Process is running"
          if [ -e "#{fetch(:puma_config)}" ]; then
            echo "[DEBUG] Using config file for #{command}"
            cd #{fetch(:puma_root_path)} && #{fetch(:pumactl_cmd)} -F #{fetch(:puma_config)} #{command}
            echo "[DEBUG] Command exit code: $?"
          else
            echo "[DEBUG] Using socket for #{command}"
            cd #{fetch(:puma_root_path)} && #{fetch(:pumactl_cmd)} -S #{fetch(:puma_state)} -C "unix://#{fetch(:pumactl_socket)}" --pidfile #{fetch(:puma_pid)} #{command}
            echo "[DEBUG] Command exit code: $?"
          fi
        else
          echo "[DEBUG] Process is not running, removing stale PID file"
          rm "#{fetch(:puma_pid)}"
        fi
      else
        echo 'Puma is not running!';
      fi
    }
    command debug_cmd(1, cmd)
  end

  def pumactl_restart_command(command)
    puma_port_option = "-p #{fetch(:puma_port)}" if set?(:puma_port)

    cmd =  %{
      echo "[DEBUG] Starting restart command: #{command}"
      if [ -e "#{fetch(:puma_pid)}"  ] && kill -0 "$(cat #{fetch(:puma_pid)})" 2> /dev/null; then
        echo "[DEBUG] Process is running, attempting #{command}"
        if [ -e "#{fetch(:puma_config)}" ]; then
          echo "[DEBUG] Using config file"
          cd #{fetch(:puma_root_path)} && #{fetch(:pumactl_cmd)} -F #{fetch(:puma_config)} #{command}
          echo "[DEBUG] Command exit code: $?"
        else
          echo "[DEBUG] Using socket"
          cd #{fetch(:puma_root_path)} && #{fetch(:pumactl_cmd)} -S #{fetch(:puma_state)} -C "unix://#{fetch(:pumactl_socket)}" --pidfile #{fetch(:puma_pid)} #{command}
          echo "[DEBUG] Command exit code: $?"
        fi
      else
        echo "[DEBUG] Puma is not running, starting fresh"
        if [ -e "#{fetch(:puma_config)}" ]; then
          echo "[DEBUG] Using config file for start"
          cd #{fetch(:puma_root_path)} && #{fetch(:puma_cmd)} -q -e #{fetch(:puma_env)} -C #{fetch(:puma_config)}
          echo "[DEBUG] Start exit code: $?"
        else
          echo "[DEBUG] Using command line options for start"
          cd #{fetch(:puma_root_path)} && #{fetch(:puma_cmd)} -q -e #{fetch(:puma_env)} -b "unix://#{fetch(:puma_socket)}" #{puma_port_option} -S #{fetch(:puma_state)} --pidfile #{fetch(:puma_pid)} --control 'unix://#{fetch(:pumactl_socket)}' --redirect-stdout "#{fetch(:puma_stdout)}" --redirect-stderr "#{fetch(:puma_stderr)}"
          echo "[DEBUG] Start exit code: $?"
        fi
      fi
    }
    command debug_cmd(1, cmd)
  end

  def wait_phased_restart_successful_command(default_times = 120, exit_script = nil)
    default_exit_script = %{
      echo "Please check it manually!!!"
      exit 1
    }
    exit_script ||= default_exit_script
    cmd = %{
      # Debug: Show command and line numbers while executing
      echo "[DEBUG] Starting wait_phased_restart_successful_command, timeout: #{default_times}s"
      
      started_flag=false
      default_times=#{default_times}
      times=$default_times
      
      echo "[DEBUG] Current directory before cd: $(pwd)"
      cd #{fetch(:puma_root_path)}
      echo "[DEBUG] Current directory after cd: $(pwd)"
      
      echo "Waiting phased-restart finish( default: $default_times seconds)..."
      
      while [ $times -gt 0 ]; do
        echo "[DEBUG] Remaining time: $times seconds"
        
        if [ -e "#{fetch(:puma_config)}" ]; then
          echo "[DEBUG] Using config file for stats"
          # Just output the old workers number
          #{fetch(:pumactl_cmd)} -F #{fetch(:puma_config)} stats | grep -E -o '"old_workers": [0-9]+'
          
          if #{fetch(:pumactl_cmd)} -F #{fetch(:puma_config)} stats | grep '"old_workers": 0';then
            echo "[DEBUG] Found old_workers: 0, restart complete"
            started_flag=true
            break
          fi
        else
          echo "[DEBUG] Using socket for stats"
          # Just output the old workers number
          #{fetch(:pumactl_cmd)} -S #{fetch(:puma_state)} -C "unix://#{fetch(:pumactl_socket)}" --pidfile #{fetch(:puma_pid)} stats | grep -E -o '"old_workers": [0-9]+'
          
          if #{fetch(:pumactl_cmd)} -S #{fetch(:puma_state)} -C "unix://#{fetch(:pumactl_socket)}" --pidfile #{fetch(:puma_pid)} stats | grep '"old_workers": 0'; then
            echo "[DEBUG] Found old_workers: 0, restart complete"
            started_flag=true
            break
          fi
        fi
        
        sleep 1
        # Important: This is the line that was causing issues in ZSH
        # Changed from $[times - 1] to $((times - 1))
        echo "[DEBUG] Decrementing times from $times"
        times=$((times - 1))
        echo "[DEBUG] New times value: $times"
      done

      echo "[DEBUG] Loop completed, started_flag=$started_flag"
      if [ "$started_flag" = false ]; then
        echo "Waiting phased-restart timeout(default: $default_times seconds)..."
        echo "[DEBUG] About to execute exit script"
        #{exit_script}
      else
        echo "Phased-restart have finished, enjoy it!"
      fi
    }
    command debug_cmd(1, cmd)
  end

  def wait_quit_or_force_quit_command
    cmd = %{
      echo "[DEBUG] Starting wait_quit_or_force_quit_command"
      quit_flag=false
      times=3
      
      echo "[DEBUG] Waiting for process to quit naturally"
      while [ $times -gt 0 ]; do
        echo "[DEBUG] Remaining attempts: $times"
        if [ -e "#{fetch(:puma_pid)}" ]; then
          echo "[DEBUG] PID file still exists, sleeping"
          sleep 1
          times=$((times - 1))
        else
          echo "[DEBUG] PID file gone, process quit normally"
          quit_flag=true
          break
        fi
      done

      if [ "$quit_flag" = false ]; then
        echo "Friendly quit fail, force quit..."
        echo "[DEBUG] Attempting force kill with PID: $(cat "#{fetch(:puma_pid)}" 2>/dev/null)"

        kill -9 $(cat "#{fetch(:puma_pid)}") 2> /dev/null
        kill_result=$?
        echo "[DEBUG] kill -9 exit code: $kill_result"

        force_quit_flag=false
        force_times=3
        echo "[DEBUG] Waiting to confirm force quit"
        while [ $force_times -gt 0 ]; do
          echo "[DEBUG] Force quit check remaining: $force_times"
          if [ -e "#{fetch(:puma_pid)}" ] && kill -0 $(cat "#{fetch(:puma_pid)}") 2> /dev/null; then
            echo "[DEBUG] Process still running, waiting"
            sleep 1
            force_times=$((force_times - 1))
          else
            echo "[DEBUG] Process successfully terminated"
            force_quit_flag=true
            echo "Force quit successfully"
            break
          fi
        done

        if [ "$force_quit_flag" = false ]; then
          echo "[DEBUG] Force quit failed after multiple attempts"
          echo "Force quit fail too, please check the script!!!"
          exit 1
        fi
      else
        echo "Friendly quit successfully"
      fi
    }
    command debug_cmd(1, cmd)
  end
end
