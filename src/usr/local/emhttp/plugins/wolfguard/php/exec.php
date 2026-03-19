<?php
// WolfGuard AJAX handler
// Called by the settings/status pages for dynamic actions

// Require valid Unraid session (emhttpd gates access, but verify explicitly)
session_start();
if (empty($_SERVER['HTTP_X_REQUESTED_WITH']) || $_SERVER['HTTP_X_REQUESTED_WITH'] !== 'XMLHttpRequest') {
    // Only accept AJAX requests — blocks direct browser/cross-origin POSTs
    http_response_code(403);
    echo json_encode(['error' => 'AJAX requests only']);
    exit;
}

$action = $_POST['action'] ?? '';
$plugin_dir = '/usr/local/emhttp/plugins/wolfguard';
$cfg_file = '/boot/config/plugins/wolfguard/wolfguard.cfg';
$status_file = '/boot/config/plugins/wolfguard/status.json';

// Allowlist of valid actions
$allowed_actions = ['get_vms', 'get_vm_info', 'get_status', 'get_backup_info', 'run_backup', 'get_logs', 'is_running'];
if (!in_array($action, $allowed_actions, true)) {
    http_response_code(400);
    echo json_encode(['error' => 'Unknown action']);
    exit;
}

switch ($action) {
    case 'get_vms':
        // List all VMs from libvirt
        $output = [];
        exec("virsh list --all --name 2>/dev/null", $output);
        $vms = array_filter(array_map('trim', $output));
        echo json_encode(array_values($vms));
        break;

    case 'get_vm_info':
        // Get details for all VMs
        $output = [];
        exec("virsh list --all --name 2>/dev/null", $output);
        $vms = array_filter(array_map('trim', $output));
        $info = [];
        foreach ($vms as $vm) {
            $state_out = [];
            exec("virsh domstate " . escapeshellarg($vm) . " 2>/dev/null", $state_out);
            $state = trim($state_out[0] ?? 'unknown');

            $disk_out = [];
            exec("virsh domblklist " . escapeshellarg($vm) . " --details 2>/dev/null | awk '\$2 == \"disk\" { print \$4 }'", $disk_out);
            $disks = array_filter(array_map('trim', $disk_out));

            $total_size = 0;
            foreach ($disks as $disk) {
                if (file_exists($disk)) {
                    $total_size += filesize($disk);
                }
            }

            $info[] = [
                'name' => $vm,
                'state' => $state,
                'disk_count' => count($disks),
                'disk_size_gb' => round($total_size / (1024*1024*1024), 1),
            ];
        }
        echo json_encode($info);
        break;

    case 'get_status':
        // Read last backup status
        if (file_exists($status_file)) {
            echo file_get_contents($status_file);
        } else {
            echo json_encode(['last_run' => 'Never', 'exit_code' => -1, 'succeeded' => [], 'failed' => []]);
        }
        break;

    case 'get_backup_info':
        // Get per-VM backup info
        $cfg = parse_plugin_cfg('wolfguard');
        $backup_dir = $cfg['BACKUP_DIR'] ?? '/mnt/user/claudebackups/wolfguard';
        $result = [];
        if (is_dir($backup_dir)) {
            foreach (scandir($backup_dir) as $vm_dir) {
                if ($vm_dir === '.' || $vm_dir === '..') continue;
                $full_path = "$backup_dir/$vm_dir";
                if (!is_dir($full_path)) continue;

                $backups = glob("$full_path/*.img.zst");
                $xmls = glob("$full_path/*.xml");
                $total_size = 0;
                $latest_time = 0;
                foreach ($backups as $b) {
                    $total_size += filesize($b);
                    $mtime = filemtime($b);
                    if ($mtime > $latest_time) $latest_time = $mtime;
                }

                $result[] = [
                    'vm' => $vm_dir,
                    'backup_count' => count($backups),
                    'total_size_gb' => round($total_size / (1024*1024*1024), 1),
                    'latest' => $latest_time > 0 ? date('Y-m-d H:i:s', $latest_time) : 'Never',
                ];
            }
        }
        echo json_encode($result);
        break;

    case 'run_backup':
        // Trigger a manual backup run (async)
        $vm = $_POST['vm'] ?? '';
        if ($vm) {
            exec("nohup $plugin_dir/scripts/wolfguard-backup.sh --vm " . escapeshellarg($vm) . " --force > /dev/null 2>&1 &");
            echo json_encode(['status' => 'started', 'vm' => $vm]);
        } else {
            exec("nohup $plugin_dir/scripts/wolfguard-backup.sh --force > /dev/null 2>&1 &");
            echo json_encode(['status' => 'started', 'vm' => 'all']);
        }
        break;

    case 'get_logs':
        // Return recent log entries
        $log_dir = '/var/log/wolfguard';
        $logs = glob("$log_dir/wolfguard-*.log");
        if (empty($logs)) {
            echo json_encode(['logs' => 'No logs yet.']);
            break;
        }
        rsort($logs);  // Most recent first
        $latest = $logs[0];
        $content = file_get_contents($latest);
        // Limit to last 100 lines
        $lines = explode("\n", $content);
        $lines = array_slice($lines, -100);
        echo json_encode(['log_file' => basename($latest), 'logs' => implode("\n", $lines)]);
        break;

    case 'is_running':
        // Check if a backup is currently running
        $running = file_exists('/var/run/wolfguard.lock');
        if ($running) {
            $pid = trim(file_get_contents('/var/run/wolfguard.lock'));
            $running = file_exists("/proc/$pid");
        }
        echo json_encode(['running' => $running]);
        break;

    default:
        echo json_encode(['error' => 'Unknown action']);
        break;
}
?>
