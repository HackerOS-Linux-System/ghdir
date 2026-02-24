package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:time"
import "core:net/http"
import "core:encoding/json"
import "core:compress/gzip"
import "core:io"
import "core:mem"
import "core:slice"
import "core:math"

title_style   :: "\x1b[1;38;5;86m"  // Bold, cyan-like
success_style :: "\x1b[1;38;5;82m"  // Bold, green
error_style   :: "\x1b[1;31m"       // Bold, red
warning_style :: "\x1b[1;38;5;208m" // Bold, orange
info_style    :: "\x1b[1;38;5;39m"  // Bold, blue
reset         :: "\x1b[0m"

main :: proc() {
    args := os.args[1:]
    if len(args) < 1 {
        print_usage()
        os.exit(1)
    }

    subcmd := args[0]
    subargs := args[1:]

    switch subcmd {
    case "file":
        handle_file(subargs)
    case "repo":
        handle_repo(subargs)
    case "dir":
        handle_dir(subargs)
    case:
        fmt.printf("%sBłąd: Nieznana komenda '%s'%s\n", error_style, subcmd, reset)
        print_usage()
        os.exit(1)
    }
}

print_usage :: proc() {
    fmt.printf("%sgetit • Uniwersalne narzędzie do pobierania i zarządzania%s\n\n", title_style, reset)
    fmt.println("Użycie:")
    fmt.printf("  %sgetit file <link> [flagi]%s   - Pobierz pojedynczy plik (jak curl/wget)\n", info_style, reset)
    fmt.printf("  %sgetit repo <link.git> [flagi]%s - Operacje git (np. -clone, -push)\n", info_style, reset)
    fmt.printf("  %sgetit dir <katalog github> [flagi]%s - Pobierz folder z GitHub\n\n", info_style, reset)
    fmt.println("Flagi ogólne: -h (pomoc)")
}

handle_file :: proc(args: []string) {
    if len(args) < 1 {
        fmt.printf("%sBłąd: Podaj link do pliku%s\n", error_style, reset)
        os.exit(1)
    }
    url := args[0]
    filename := filepath.base(url) if !strings.contains(url, "?") else strings.split(url, "?")[0] // Proste wyodrębnienie nazwy

    fmt.printf("%sgetit file • Pobieranie pliku%s\n", title_style, reset)
    fmt.printf(" URL: %s\n", url)
    fmt.printf(" Zapisywanie jako: %s\n\n", filename)

    resp, err := http.get(url)
    if err != .None {
        fmt.printf("%sBłąd: Nie można pobrać pliku (%v)%s\n", error_style, err, reset)
        os.exit(1)
    }
    defer http.response_destroy(&resp)

    if resp.status != 200 {
        fmt.printf("%sBłąd: Status HTTP %d%s\n", error_style, resp.status, reset)
        os.exit(1)
    }

    file, file_err := os.open(filename, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
    if file_err != 0 {
        fmt.printf("%sBłąd: Nie można utworzyć pliku%s\n", error_style, reset)
        os.exit(1)
    }
    defer os.close(file)

    content_length := resp.content_length if resp.content_length > 0 else len(resp.body)
    bar := new_progress_bar(i64(content_length), "Pobieranie")

    reader := io.Reader{context = context, data = resp.body}
    buf: [4096]byte
    total: i64 = 0
    for {
        n, rerr := io.read(&reader, buf[:])
        if n > 0 {
            os.write(file, buf[:n])
            total += i64(n)
            update_progress_bar(&bar, total)
        }
        if rerr == .EOF { break }
        if rerr != .None {
            fmt.printf("%sBłąd podczas pobierania%s\n", error_style, reset)
            os.exit(1)
        }
    }

    fmt.printf("\n%sGotowe! Pobrano plik: %s%s\n", success_style, filename, reset)
}

handle_repo :: proc(args: []string) {
    if len(args) < 1 {
        fmt.printf("%sBłąd: Podaj link do repozytorium.git%s\n", error_style, reset)
        os.exit(1)
    }
    link := args[0]
    flags := args[1:]

    fmt.printf("%sgetit repo • Operacje Git%s\n", title_style, reset)
    fmt.printf(" Repo: %s\n\n", link)

    clone := false
    push := false
    for flag in flags {
        switch flag {
        case "-clone": clone = true
        case "-push": push = true
        case "-h":
            fmt.println("Flagi: -clone (klonuj), -push (push do remote)")
            return
        case:
            fmt.printf("%sOstrzeżenie: Nieznana flaga '%s'%s\n", warning_style, flag, reset)
        }
    }

    if clone {
        fmt.printf("%sKlonowanie repozytorium...%s\n", info_style, reset)
        err := run_command("git", "clone", link)
        if err != nil {
            fmt.printf("%sBłąd podczas klonowania: %v%s\n", error_style, err, reset)
            os.exit(1)
        }
        fmt.printf("%sRepozytorium sklonowane pomyślnie%s\n", success_style, reset)
    } else if push {
        fmt.printf("%sPushowanie zmian...%s\n", info_style, reset)
        err := run_command("git", "remote", "add", "origin", link) // Zakładamy dodanie remote jeśli potrzeba
        if err != nil { /* ignore if exists */ }
        err = run_command("git", "push", "origin", "main") // Zakładamy branch main
        if err != nil {
            fmt.printf("%sBłąd podczas push: %v%s\n", error_style, err, reset)
            os.exit(1)
        }
        fmt.printf("%sZmiany wypchnięte pomyślnie%s\n", success_style, reset)
    } else {
        fmt.printf("%sBłąd: Podaj flagę, np. -clone lub -push%s\n", error_style, reset)
        os.exit(1)
    }
}

handle_dir :: proc(args: []string) {
    if len(args) < 1 {
        fmt.printf("%sBłąd: Podaj URL folderu GitHub%s\n", error_style, reset)
        os.exit(1)
    }
    raw_url := args[0]
    user, repo, branch, folder := parse_github_url(raw_url)

    fmt.printf("%sgetit dir • Pobieranie folderu z GitHub%s\n", title_style, reset)
    fmt.printf(" %s/%s • %s\n", user, repo, branch)
    if folder != "" {
        fmt.printf(" Folder: %s\n", folder)
    }

    tar_url := fmt.tprintf("https://github.com/%s/%s/archive/refs/heads/%s.tar.gz", user, repo, branch)

    cache := load_cache()
    key := fmt.tprintf("%s/%s/%s/%s", user, repo, branch, folder)
    etag := cache[key] or_else ""

    fmt.printf("\n%sSprawdzanie repozytorium...%s\n", info_style, reset)
    head_req := http.Request{method = .Head, url = tar_url}
    if etag != "" {
        head_req.headers["If-None-Match"] = etag
    }
    head_resp, head_err := http.request(head_req)
    if head_err != .None {
        fmt.printf("%sBłąd: Nie można sprawdzić repozytorium (%v)%s\n", error_style, head_err, reset)
        os.exit(1)
    }
    defer http.response_destroy(&head_resp)

    if head_resp.status == 304 {
        fmt.printf("%sFolder jest aktualny. Brak zmian.%s\n", success_style, reset)
        return
    }
    if head_resp.status != 200 {
        fmt.printf("%sBłąd: Nie można uzyskać dostępu (status %d)%s\n", error_style, head_resp.status, reset)
        os.exit(1)
    }

    content_length := head_resp.content_length
    use_sparse := folder != "" && content_length > 500*1024*1024 // 500 MB

    large_threshold :: 2 * 1024 * 1024 * 1024 // 2 GB
    if content_length > large_threshold {
        size_mb := content_length / (1024 * 1024)
        fmt.printf("%sOstrzeżenie: Archiwum jest duże (%d MB). To może zająć dużo czasu.%s\n", warning_style, size_mb, reset)
        fmt.print("Kontynuować? (y/n) ")
        input: [1024]byte
        n, _ := os.read(os.stdin, input[:])
        inp_str := strings.trim_space(string(input[:n]))
        if strings.to_lower(inp_str) != "y" {
            fmt.println("Przerwano.")
            return
        }
    }

    new_etag: string
    count: int
    if use_sparse {
        fmt.printf("\n%sArchiwum jest duże, używam git sparse-checkout...%s\n", info_style, reset)
        err := download_with_sparse(user, repo, branch, folder)
        if err != nil {
            fmt.printf("%sBłąd podczas sparse: %v%s\n", error_style, err, reset)
            os.exit(1)
        }
        count = count_files_and_folders(get_last_folder(folder))
    } else {
        fmt.printf("\n%sPobieranie archiwum...%s\n", info_style, reset)
        get_req := http.Request{method = .Get, url = tar_url}
        if etag != "" {
            get_req.headers["If-None-Match"] = etag
        }
        resp, get_err := http.request(get_req)
        if get_err != .None {
            fmt.printf("%sBłąd: Nie można pobrać (%v)%s\n", error_style, get_err, reset)
            os.exit(1)
        }
        defer http.response_destroy(&resp)

        if resp.status == 304 {
            fmt.printf("%sFolder jest aktualny.%s\n", success_style, reset)
            return
        }
        if resp.status != 200 {
            fmt.printf("%sBłąd: Status %d%s\n", error_style, resp.status, reset)
            os.exit(1)
        }

        new_etag = resp.headers["ETag"] or_else ""

        bar := new_progress_bar(i64(len(resp.body)), "Pobieranie")

        gz_ctx: gzip.Context
        gzip.init(&gz_ctx, resp.body)
        defer gzip.destroy(&gz_ctx)

        fmt.printf("\n%sRozpakowywanie plików...%s\n", info_style, reset)

        extract_dir := "."
        atomic := folder != ""
        temp_dir: string
        if atomic {
            temp_dir = fmt.tprintf("getit_temp_%d", time.now()._nsec / 1_000_000_000)
            os.make_directory(temp_dir)
        } else {
            temp_dir = extract_dir
        }

        strip := calculate_strip(repo, branch, folder)
        extract_strip := strip + 1 if atomic else strip

        count = extract_tar(&gz_ctx, temp_dir, extract_strip)

        update_progress_bar(&bar, i64(len(resp.body))) // Final update

        if atomic {
            target_dir := get_last_folder(folder)
            old_dir: string
            if os.exists(target_dir) {
                old_dir = fmt.tprintf("%s.old.%d", target_dir, time.now()._nsec / 1_000_000_000)
                os.rename(target_dir, old_dir)
            }
            err := os.rename(temp_dir, target_dir)
            if err != 0 {
                if old_dir != "" {
                    os.rename(old_dir, target_dir)
                }
                os.remove_directory(temp_dir)
                fmt.printf("%sBłąd podczas atomic rename%s\n", error_style, reset)
                os.exit(1)
            }
            if old_dir != "" {
                os.remove_directory(old_dir)
            }
        }
    }

    fmt.printf("%s\nGotowe! Pobrano %d plików/folderów%s\n", success_style, count, reset)
    fmt.printf(" → %s./%s%s\n", success_style, get_last_folder(folder), reset)

    if new_etag != "" {
        cache[key] = new_etag
        save_cache(cache)
    }
}

// Prosty ekstraktor tar (basic implementation)
extract_tar :: proc(gz_ctx: ^gzip.Context, extract_dir: string, extract_strip: int) -> int {
    count := 0
    buf: [512]byte // Tar header size
    for {
        header_data, err := gzip.read(gz_ctx, buf[:])
        if err == .EOF { break }
        if len(header_data) != 512 {
            return count // Error, but simplified
        }

        name := strings.trim_null(string(buf[0:100]))
        if name == "" { continue }

        mode_str := string(buf[100:108])
        size_str := string(buf[124:136])
        mode, _ := strconv.parse_u64(mode_str, 8)
        size, _ := strconv.parse_i64(size_str, 8)

        parts := strings.split(name, "/")
        if len(parts) <= extract_strip { 
            if size > 0 {
                skip_data(gz_ctx, size)
            }
            continue 
        }
        target := filepath.join(extract_dir, parts[extract_strip:]...)

        typeflag := buf[156]
        if typeflag == '5' { // Directory
            os.make_directory(target, u32(mode))
            count += 1
            continue
        } else if typeflag == '0' || typeflag == 0 { // File
            os.make_directory(filepath.dir(target))
            file, _ := os.open(target, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, u32(mode))
            defer os.close(file)

            remaining := size
            data_buf: [4096]byte
            while remaining > 0 {
                to_read := min(4096, int(remaining))
                data, derr := gzip.read(gz_ctx, data_buf[:to_read])
                if derr != .None && derr != .EOF { break }
                os.write(file, data)
                remaining -= i64(len(data))
            }
            count += 1
        } else {
            if size > 0 {
                skip_data(gz_ctx, size)
            }
        }
    }
    return count
}

skip_data :: proc(gz_ctx: ^gzip.Context, size: i64) {
    buf: [4096]byte
    remaining := size
    while remaining > 0 {
        to_read := min(4096, int(remaining))
        _, err := gzip.read(gz_ctx, buf[:to_read])
        if err == .EOF { break }
        remaining -= i64(to_read)
    }
}

parse_github_url :: proc(raw: string) -> (user, repo, branch, folder: string) {
    parts := strings.split(strings.trim(raw, "/"), "/")
    if len(parts) < 2 {
        fmt.printf("%sBłąd: Nieprawidłowy URL GitHub%s\n", error_style, reset)
        os.exit(1)
    }
    user = parts[0]
    repo = parts[1]
    for i := 0; i < len(parts); i += 1 {
        if parts[i] == "tree" && i+1 < len(parts) {
            branch = parts[i+1]
            if i+2 < len(parts) {
                folder = strings.join(parts[i+2:], "/")
            }
            return
        }
    }
    branch = "main"
    return
}

calculate_strip :: proc(repo, branch, folder: string) -> int {
    return 1 + strings.count(folder, "/")
}

get_last_folder :: proc(folder: string) -> string {
    if folder == "" { return "." }
    parts := strings.split(folder, "/")
    return parts[len(parts)-1]
}

load_cache :: proc() -> map[string]string {
    config_dir := os.get_env("XDG_CONFIG_HOME") // Approximate
    if config_dir == "" {
        home := os.get_env("HOME")
        config_dir = filepath.join(home, ".config")
    }
    dir := filepath.join(config_dir, "getit")
    os.make_directory(dir)
    file := filepath.join(dir, "cache.json")
    data, ok := os.read_entire_file(file)
    if !ok { return make(map[string]string) }
    cache: map[string]string
    json.unmarshal(data, &cache)
    return cache
}

save_cache :: proc(cache: map[string]string) {
    config_dir := os.get_env("XDG_CONFIG_HOME")
    if config_dir == "" {
        home := os.get_env("HOME")
        config_dir = filepath.join(home, ".config")
    }
    dir := filepath.join(config_dir, "getit")
    file := filepath.join(dir, "cache.json")
    data, err := json.marshal(cache, indent=2)
    if err != nil { return }
    os.write_entire_file(file, data)
}

download_with_sparse :: proc(user, repo, branch, folder: string) -> error {
    temp_dir := fmt.tprintf("getit_sparse_%d", time.now()._nsec / 1_000_000_000)
    os.make_directory(temp_dir)
    defer if err != nil { os.remove_directory(temp_dir) }

    git_url := fmt.tprintf("https://github.com/%s/%s.git", user, repo)

    cmds := [][]string{
        {"git", "clone", "-b", branch, "--filter=blob:none", "--no-checkout", git_url, temp_dir},
        {"git", "-C", temp_dir, "sparse-checkout", "init", "--cone"},
        {"git", "-C", temp_dir, "sparse-checkout", "set", folder},
        {"git", "-C", temp_dir, "checkout", branch},
    }

    for cmd in cmds {
        err := run_command(cmd[0], ..cmd[1:])
        if err != nil { return err }
    }

    os.remove_directory(filepath.join(temp_dir, ".git"))

    folder_path := strings.replace_all(folder, "/", string(os.path_separator))
    src_dir := filepath.join(temp_dir, folder_path)

    target_dir := get_last_folder(folder)
    old_dir: string
    if os.exists(target_dir) {
        old_dir = fmt.tprintf("%s.old.%d", target_dir, time.now()._nsec / 1_000_000_000)
        os.rename(target_dir, old_dir)
    }

    err = os.rename(src_dir, target_dir)
    if err != nil {
        if old_dir != "" {
            os.rename(old_dir, target_dir)
        }
        return err
    }

    if old_dir != "" {
        os.remove_directory(old_dir)
    }

    os.remove_directory(temp_dir) // Clean up
    return nil
}

count_files_and_folders :: proc(dir: string) -> int {
    count := 0
    walker := proc(path: string, info: os.File_Info, err: error) -> error {
        if err != nil { return err }
        count += 1
        return nil
    }
    filepath.walk(dir, walker)
    return count - 1 // Subtract root
}

run_command :: proc(cmd: string, args: ..string) -> error {
    full_cmd := slice.concat([]string{cmd}, args[:])
    proc := os.proc_from_cmdline(strings.join(full_cmd, " "))
    os.proc_wait(proc)
    if os.proc_exit_code(proc) != 0 {
        return fmt.errorf("Komenda '%s' zakończona błędem", cmd)
    }
    return nil
}

// Prosty progress bar
Progress_Bar :: struct {
    total: i64,
    current: i64,
    description: string,
    last_print: time.Time,
}

new_progress_bar :: proc(total: i64, desc: string) -> Progress_Bar {
    return {total = total, description = desc, last_print = time.now()}
}

update_progress_bar :: proc(bar: ^Progress_Bar, current: i64) {
    bar.current = current
    now := time.now()
    if time.diff(now, bar.last_print) < time.Second / 10 { return }
    bar.last_print = now

    percent := f64(bar.current) / f64(bar.total) * 100
    width := 50
    filled := int(math.round(percent / 100 * f64(width)))
    bar_str := strings.repeat("=", filled) + strings.repeat("-", width - filled)

    fmt.printf("\r%s [%s] %.2f%%", bar.description, bar_str, percent)
    if bar.current >= bar.total {
        fmt.println()
    }
}
