package main
import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:time"
import "core:encoding/json"
import "core:compress/gzip"
import "core:io"
import "core:mem"
import "core:slice"
import "core:math"
import "core:strconv"
import "base:runtime"
import "vendor:curl"
import "core:c/libc"
import "core:bytes"
title_style :: "\x1b[1;38;5;86m" // Bold, cyan-like
success_style :: "\x1b[1;38;5;82m" // Bold, green
error_style :: "\x1b[1;31m" // Bold, red
warning_style :: "\x1b[1;38;5;208m" // Bold, orange
info_style :: "\x1b[1;38;5;39m" // Bold, blue
reset :: "\x1b[0m"
main :: proc() {
    curl.global_init(curl.GLOBAL_ALL)
    defer curl.global_cleanup()
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
    fmt.printf(" %sgetit file <link> [flagi]%s - Pobierz pojedynczy plik (jak curl/wget)\n", info_style, reset)
    fmt.printf(" %sgetit repo <link.git> [flagi]%s - Operacje git (np. -clone, -push)\n", info_style, reset)
    fmt.printf(" %sgetit dir <katalog github> [flagi]%s - Pobierz folder z GitHub\n\n", info_style, reset)
    fmt.println("Flagi ogólne: -h (pomoc)")
}
Progress_Bar :: struct {
    total: i64,
    current: i64,
    description: string,
    last_print: time.Time,
}
new_progress_bar :: proc(total: i64, desc: string) -> Progress_Bar {
    return {total = total, description = desc, last_print = time.now()}
}
update_progress_bar :: proc(bar: ^Progress_Bar, current: i64 = -1) {
    if current >= 0 {
        bar.current = current
    }
    now := time.now()
    if time.diff(now, bar.last_print) < time.Second / 10 { return }
    bar.last_print = now
    percent: f64 = 0
    if bar.total > 0 {
        percent = f64(bar.current) / f64(bar.total) * 100
    } else {
        fmt.printf("\r%s [Pobieranie...] %d bytes", bar.description, bar.current)
        return
    }
    width := 50
    filled := int(math.round(percent / 100 * f64(width)))
    context = runtime.default_context()
    bar_str := strings.concatenate({strings.repeat("=", filled), strings.repeat("-", width - filled)})
    fmt.printf("\r%s [%s] %.2f%%", bar.description, bar_str, percent)
    if bar.current >= bar.total {
        fmt.println()
    }
}
progress_callback :: proc "c" (userdata: rawptr, dltotal: f64, dlnow: f64, ultotal: f64, ulnow: f64) -> int {
    bar := cast(^Progress_Bar)userdata
    context = runtime.default_context()
    update_progress_bar(bar, i64(dlnow))
    return 0
}
write_callback :: proc "c" (ptr: rawptr, size: uintptr, nmemb: uintptr, userdata: rawptr) -> uintptr {
    data := cast(^[dynamic]byte)userdata
    sl := transmute([]byte)mem.ptr_to_bytes(cast(^u8)ptr, int(size * nmemb))
    context = runtime.default_context()
    append(data, ..sl)
    return size * nmemb
}
header_callback :: proc "c" (ptr: rawptr, size: uintptr, nmemb: uintptr, userdata: rawptr) -> uintptr {
    hd := cast(^map[string]string)userdata
    line_bytes := mem.ptr_to_bytes(cast(^u8)ptr, int(size * nmemb))
    context = runtime.default_context()
    line := strings.trim_space(string(line_bytes))
    if len(line) == 0 { return size * nmemb }
    if strings.contains(line, ":") {
        parts := strings.split_n(line, ":", 2)
        key := strings.trim_space(strings.to_lower(parts[0]))
        value := strings.trim_space(parts[1])
        hd[key] = value
    }
    return size * nmemb
}
handle_file :: proc(args: []string) {
    if len(args) < 1 {
        fmt.printf("%sBłąd: Podaj link do pliku%s\n", error_style, reset)
        os.exit(1)
    }
    url := args[0]
    filename := filepath.base(url) if !strings.contains(url, "?") else strings.split(url, "?")[0]
    fmt.printf("%sgetit file • Pobieranie pliku%s\n", title_style, reset)
    fmt.printf(" URL: %s\n", url)
    fmt.printf(" Zapisywanie jako: %s\n\n", filename)
    // HEAD to get content_length
    head_handle := curl.easy_init()
    defer curl.easy_cleanup(head_handle)
    curl.easy_setopt(head_handle, .URL, url)
    curl.easy_setopt(head_handle, .NOBODY, i64(1))
    res := curl.easy_perform(head_handle)
    if res != .E_OK {
        fmt.printf("%sBłąd: Nie można pobrać pliku (%s)%s\n", error_style, curl.easy_strerror(res), reset)
        os.exit(1)
    }
    status: i64
    curl.easy_getinfo(head_handle, .RESPONSE_CODE, &status)
    if status != 200 {
        fmt.printf("%sBłąd: Status HTTP %d%s\n", error_style, status, reset)
        os.exit(1)
    }
    content_length: i64 = -1
    curl.easy_getinfo(head_handle, .CONTENT_LENGTH_DOWNLOAD_T, &content_length)
    // Open file
    c_filename := strings.clone_to_cstring(filename, context.temp_allocator)
    f := libc.fopen(c_filename, "wb")
    if f == nil {
        fmt.printf("%sBłąd: Nie można utworzyć pliku%s\n", error_style, reset)
        os.exit(1)
    }
    defer libc.fclose(f)
    // GET
    get_handle := curl.easy_init()
    defer curl.easy_cleanup(get_handle)
    curl.easy_setopt(get_handle, .URL, url)
    curl.easy_setopt(get_handle, .WRITEDATA, f)
    bar := new_progress_bar(content_length, "Pobieranie")
    curl.easy_setopt(get_handle, .XFERINFODATA, &bar)
    curl.easy_setopt(get_handle, .XFERINFOFUNCTION, progress_callback)
    curl.easy_setopt(get_handle, .NOPROGRESS, i64(0))
    res = curl.easy_perform(get_handle)
    if res != .E_OK {
        fmt.printf("%sBłąd podczas pobierania (%s)%s\n", error_style, curl.easy_strerror(res), reset)
        os.exit(1)
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
        if err != "" {
            fmt.printf("%sBłąd podczas klonowania: %s%s\n", error_style, err, reset)
            os.exit(1)
        }
        fmt.printf("%sRepozytorium sklonowane pomyślnie%s\n", success_style, reset)
    } else if push {
        fmt.printf("%sPushowanie zmian...%s\n", info_style, reset)
        err := run_command("git", "remote", "add", "origin", link) // Zakładamy dodanie remote jeśli potrzeba
        if err != "" { /* ignore if exists */ }
        err = run_command("git", "push", "origin", "main") // Zakładamy branch main
        if err != "" {
            fmt.printf("%sBłąd podczas push: %s%s\n", error_style, err, reset)
            os.exit(1)
        }
        fmt.printf("%sZmiany wypchnięte pomyślnie%s\n", success_style, reset)
    } else {
        fmt.printf("%sBłąd: Podaj flagę, np. -clone lub -push%s\n", error_style, reset)
        os.exit(1)
    }
}
run_command :: proc(cmd: string, args: ..string) -> (err: string) {
    full_cmd := make([]string, 1 + len(args))
    defer delete(full_cmd)
    full_cmd[0] = cmd
    copy(full_cmd[1:], args)
    context = runtime.default_context()
    full_cmd_str := strings.join(full_cmd, " ")
    defer delete(full_cmd_str)
    cstr := strings.clone_to_cstring(full_cmd_str)
    defer delete(cstr)
    ret := libc.system(cstr)
    if ret != 0 {
        return fmt.tprintf("Komenda '%s' zakończona błędem %d", cmd, ret)
    }
    return ""
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
    head_handle := curl.easy_init()
    defer curl.easy_cleanup(head_handle)
    curl.easy_setopt(head_handle, .URL, tar_url)
    slist: ^curl.slist
    if etag != "" {
        if_none_match := fmt.tprintf("If-None-Match: %s", etag)
        c_if_none_match := strings.clone_to_cstring(if_none_match, context.temp_allocator)
        slist = curl.slist_append(nil, c_if_none_match)
        curl.easy_setopt(head_handle, .HTTPHEADER, slist)
    }
    defer if slist != nil { curl.slist_free_all(slist) }
    curl.easy_setopt(head_handle, .NOBODY, i64(1))
    hd: map[string]string
    defer delete(hd)
    curl.easy_setopt(head_handle, .HEADERDATA, &hd)
    curl.easy_setopt(head_handle, .HEADERFUNCTION, header_callback)
    res := curl.easy_perform(head_handle)
    if res != .E_OK {
        fmt.printf("%sBłąd: Nie można sprawdzić repozytorium (%s)%s\n", error_style, curl.easy_strerror(res), reset)
        os.exit(1)
    }
    status: i64
    curl.easy_getinfo(head_handle, .RESPONSE_CODE, &status)
    if status == 304 {
        fmt.printf("%sFolder jest aktualny. Brak zmian.%s\n", success_style, reset)
        return
    }
    if status != 200 {
        fmt.printf("%sBłąd: Nie można uzyskać dostępu (status %d)%s\n", error_style, status, reset)
        os.exit(1)
    }
    content_length: i64 = -1
    curl.easy_getinfo(head_handle, .CONTENT_LENGTH_DOWNLOAD_T, &content_length)
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
    new_etag := hd["etag"] or_else ""
    count: int
    if use_sparse {
        fmt.printf("\n%sArchiwum jest duże, używam git sparse-checkout...%s\n", info_style, reset)
        err := download_with_sparse(user, repo, branch, folder)
        if err != "" {
            fmt.printf("%sBłąd podczas sparse: %s%s\n", error_style, err, reset)
            os.exit(1)
        }
        count = count_files_and_folders(get_last_folder(folder))
    } else {
        fmt.printf("\n%sPobieranie archiwum...%s\n", info_style, reset)
        get_handle := curl.easy_init()
        defer curl.easy_cleanup(get_handle)
        curl.easy_setopt(get_handle, .URL, tar_url)
        slist_get: ^curl.slist
        if etag != "" {
            if_none_match := fmt.tprintf("If-None-Match: %s", etag)
            c_if_none_match := strings.clone_to_cstring(if_none_match, context.temp_allocator)
            slist_get = curl.slist_append(nil, c_if_none_match)
            curl.easy_setopt(get_handle, .HTTPHEADER, slist_get)
        }
        defer if slist_get != nil { curl.slist_free_all(slist_get) }
        body: [dynamic]byte
        if content_length > 0 {
            reserve(&body, int(content_length))
        }
        defer delete(body)
        curl.easy_setopt(get_handle, .WRITEDATA, &body)
        curl.easy_setopt(get_handle, .WRITEFUNCTION, write_callback)
        bar := new_progress_bar(content_length, "Pobieranie")
        curl.easy_setopt(get_handle, .XFERINFODATA, &bar)
        curl.easy_setopt(get_handle, .XFERINFOFUNCTION, progress_callback)
        curl.easy_setopt(get_handle, .NOPROGRESS, i64(0))
        res = curl.easy_perform(get_handle)
        if res != .E_OK {
            fmt.printf("%sBłąd: Nie można pobrać (%s)%s\n", error_style, curl.easy_strerror(res), reset)
            os.exit(1)
        }
        curl.easy_getinfo(get_handle, .RESPONSE_CODE, &status)
        if status == 304 {
            fmt.printf("%sFolder jest aktualny.%s\n", success_style, reset)
            return
        }
        if status != 200 {
            fmt.printf("%sBłąd: Status %d%s\n", error_style, status, reset)
            os.exit(1)
        }
        buf: bytes.Buffer
        defer bytes.buffer_destroy(&buf)
        decompress_err := gzip.load_from_bytes(body[:], &buf)
        if decompress_err != nil {
            fmt.printf("%sBłąd: Nie można dekompresować archiwum%s\n", error_style, reset)
            os.exit(1)
        }
        tar_data := bytes.buffer_to_bytes(&buf)
        defer delete(tar_data)
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
        count = extract_tar(tar_data, temp_dir, extract_strip)
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
make_directory_recursive :: proc(path: string, mode: u32 = 0o777) {
    if os.exists(path) && os.is_dir(path) { return }
    parent := filepath.dir(path)
    if parent != path && parent != "." && parent != "/" {
        make_directory_recursive(parent, mode)
    }
    os.make_directory(path, mode)
}
extract_tar :: proc(tar_data: []byte, extract_dir: string, extract_strip: int) -> int {
    count := 0
    pos := 0
    for pos + 512 <= len(tar_data) {
        header := tar_data[pos:pos + 512]
        pos += 512
        name := strings.trim_null(string(header[0:100]))
        if name == "" { continue }
        mode_str := string(header[100:108])
        size_str := string(header[124:136])
        mode, _ := strconv.parse_u64(mode_str, 8)
        size, _ := strconv.parse_i64(size_str, 8)
        typeflag := header[156]
        context = runtime.default_context()
        parts := strings.split(name, "/")
        if len(parts) <= extract_strip {
            pad := (512 - (int(size) % 512)) % 512
            pos += int(size) + pad
            continue
        }
        elems: [dynamic]string
        append(&elems, extract_dir)
        append(&elems, ..parts[extract_strip:])
        target := filepath.join(elems[:])
        defer delete(elems)
        if typeflag == u8('5') { // Directory
            make_directory_recursive(target, u32(mode))
            count += 1
            pad := (512 - (int(size) % 512)) % 512
            pos += int(size) + pad
            continue
        } else if typeflag == u8('0') || typeflag == u8(0) { // File
            dir := filepath.dir(target)
            make_directory_recursive(dir)
            file, ferr := os.open(target, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, int(mode))
            if ferr != 0 {
                // Handle error if needed
                pad := (512 - (int(size) % 512)) % 512
                pos += int(size) + pad
                continue
            }
            defer os.close(file)
            data_end := pos + int(size)
            if data_end > len(tar_data) {
                break
            }
            data := tar_data[pos:data_end]
            os.write(file, data)
            pos = data_end
            pad := (512 - (int(size) % 512)) % 512
            pos += pad
            count += 1
        } else {
            pad := (512 - (int(size) % 512)) % 512
            pos += int(size) + pad
        }
    }
    return count
}
parse_github_url :: proc(raw: string) -> (user, repo, branch, folder: string) {
    context = runtime.default_context()
    url := strings.trim(raw, "/")
    if strings.has_prefix(url, "https://github.com/") {
        url = url[len("https://github.com/"):]
    } else if strings.has_prefix(url, "http://github.com/") {
        url = url[len("http://github.com/"):]
    } else if strings.has_prefix(url, "github.com/") {
        url = url[len("github.com/"):]
    }
    parts := strings.split(url, "/")
    if len(parts) < 2 {
        fmt.printf("%sBłąd: Nieprawidłowy URL GitHub%s\n", error_style, reset)
        os.exit(1)
    }
    user = parts[0]
    repo = parts[1]
    i := 2
    if i < len(parts) && parts[i] == "tree" && i + 1 < len(parts) {
        branch = parts[i + 1]
        i += 2
    } else {
        branch = "main"
        i = 2
    }
    if i < len(parts) {
        folder = strings.join(parts[i:], "/")
    }
    return
}
calculate_strip :: proc(repo, branch, folder: string) -> int {
    return 1 + strings.count(folder, "/")
}
get_last_folder :: proc(folder: string) -> string {
    if folder == "" { return "." }
    context = runtime.default_context()
    parts := strings.split(folder, "/")
    return parts[len(parts)-1]
}
load_cache :: proc() -> map[string]string {
    context = runtime.default_context()
    home := os.get_env("HOME")
    config_dir := filepath.join([]string{home, ".config"})
    dir := filepath.join([]string{config_dir, "getit"})
    os.make_directory(dir)
    file := filepath.join([]string{dir, "cache.json"})
    data, ok := os.read_entire_file(file)
    if !ok { return make(map[string]string) }
    cache: map[string]string
    err := json.unmarshal(data, &cache)
    if err != nil { return make(map[string]string) }
    return cache
}
save_cache :: proc(cache: map[string]string) {
    context = runtime.default_context()
    home := os.get_env("HOME")
    config_dir := filepath.join([]string{home, ".config"})
    dir := filepath.join([]string{config_dir, "getit"})
    file := filepath.join([]string{dir, "cache.json"})
    data, err := json.marshal(cache, {pretty = true, use_spaces = true, spaces = 2})
    if err != nil { return }
    os.write_entire_file(file, data)
}
download_with_sparse :: proc(user, repo, branch, folder: string) -> (err: string) {
    temp_dir := fmt.tprintf("getit_sparse_%d", time.now()._nsec / 1_000_000_000)
    os.make_directory(temp_dir)
    defer if err != "" { os.remove_directory(temp_dir) }
    git_url := fmt.tprintf("https://github.com/%s/%s.git", user, repo)
    cmds := [][]string{
        {"git", "clone", "-b", branch, "--filter=blob:none", "--no-checkout", git_url, temp_dir},
        {"git", "-C", temp_dir, "sparse-checkout", "init", "--cone"},
        {"git", "-C", temp_dir, "sparse-checkout", "set", folder},
        {"git", "-C", temp_dir, "checkout", branch},
    }
    for cmd in cmds {
        err = run_command(cmd[0], ..cmd[1:])
        if err != "" { return }
    }
    os.remove_directory(filepath.join([]string{temp_dir, ".git"}))
    sep_rune := filepath.SEPARATOR
    sep := fmt.tprintf("%c", sep_rune)
    folder_path, _ := strings.replace_all(folder, "/", sep)
    src_dir := filepath.join([]string{temp_dir, folder_path})
    target_dir := get_last_folder(folder)
    old_dir: string
    if os.exists(target_dir) {
        old_dir = fmt.tprintf("%s.old.%d", target_dir, time.now()._nsec / 1_000_000_000)
        os.rename(target_dir, old_dir)
    }
    rename_err := os.rename(src_dir, target_dir)
    if rename_err != 0 {
        if old_dir != "" {
            os.rename(old_dir, target_dir)
        }
        return fmt.tprintf("Błąd rename: %d", rename_err)
    }
    if old_dir != "" {
        os.remove_directory(old_dir)
    }
    os.remove_directory(temp_dir) // Clean up
    return ""
}
count_files_and_folders :: proc(dir: string) -> int {
    context = runtime.default_context()
    handle, open_err := os.open(dir, os.O_RDONLY)
    if open_err != 0 { return 0 }
    defer os.close(handle)
    entries, read_err := os.read_dir(handle, -1)
    if read_err != 0 { return 0 }
    defer {
        for e in entries {
            delete(e.fullpath)
        }
        delete(entries)
    }
    count := 1 // self
    for e in entries {
        if e.is_dir {
            full := filepath.join([]string{dir, e.name})
            count += count_files_and_folders(full)
        } else {
            count += 1
        }
    }
    return count
}
