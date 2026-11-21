@echo off
setlocal DisableDelayedExpansion
set "PYTHON_MANAGER_AUTOMATIC_INSTALL=0"
set "PYLAUNCHER_ALLOW_INSTALL="
set "PYLAUNCHER_ALWAYS_INSTALL="
set "version_check=import sys; sys.exit(sys.version_info < (3, 8))"
rem Load the embedded source while keeping console input available.
set "python_loader=import sys; from pathlib import Path; __file__ = sys.argv[1]; lines = Path(__file__).read_bytes().splitlines(); start = lines.index(b'# BEGIN PYTHON SOURCE') + 1; exec(compile(b'\n' * start + b'\n'.join(lines[start:]), __file__, 'exec'))"

python.exe -I -c "%version_check%" >nul 2>&1
if not errorlevel 1 goto use_python
py.exe -3 -I -c "%version_check%" >nul 2>&1
if not errorlevel 1 goto use_launcher
python3.exe -I -c "%version_check%" >nul 2>&1
if not errorlevel 1 goto use_python3

echo Python 3.8 or newer is required. Install Python and make it available on PATH. 1>&2
exit /b 1

:use_python
python.exe -I -X utf8 -c "%python_loader%" "%~f0"
exit /b %errorlevel%

:use_launcher
py.exe -3 -I -X utf8 -c "%python_loader%" "%~f0"
exit /b %errorlevel%

:use_python3
python3.exe -I -X utf8 -c "%python_loader%" "%~f0"
exit /b %errorlevel%

# BEGIN PYTHON SOURCE
import codecs
import os
import re
import sys
from pathlib import Path


GB_ENCODINGS = ("gb2312", "gbk", "gb18030")
AUTO_SUFFIXES = frozenset({".cpp", ".c", ".py", ".txt", ".md"})
OUTPUT_MARKER = "_tf"
UNICODE_BOMS = (
    codecs.BOM_UTF8,
    codecs.BOM_UTF16_LE,
    codecs.BOM_UTF16_BE,
    codecs.BOM_UTF32_BE,
)
BINARY_CONTROLS = re.compile(rb"[\x00-\x08\x0e-\x1f\x7f]")


def prompt_for_encoding():
    choices = {"1": "gbk", "2": "gb2312", "3": "gb18030"}
    while True:
        value = input("选择原文件编码（1 GBK / 2 GB2312 / 3 GB18030）> ").strip().lower()
        encoding = choices.get(value, value)
        if encoding in GB_ENCODINGS:
            return encoding
        print("请输入 1、2、3 或对应的编码名称。")


def prompt_for_suffixes():
    while True:
        value = input("输入文件后缀，可用逗号或空格分隔（例如 .txt, *.c）> ")
        suffixes = set()
        for token in re.split(r"[\s,，]+", value.strip()):
            match = re.fullmatch(r'(?:\*?\.)?([^\\/:*?"<>|.\x00-\x1f]+)', token)
            if match is None:
                break
            suffixes.add("." + match[1].casefold())
        else:
            return suffixes
        print("请输入至少一个有效的文件后缀，例如 txt 或 .c。")


def is_utf8(data):
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return True


def detect_gb_text(data):
    if data.startswith(UNICODE_BOMS):
        return None, "检测到 Unicode BOM"
    if BINARY_CONTROLS.search(data):
        return None, "含疑似二进制控制字节"
    if data.isascii():
        return None, "纯 ASCII，已兼容 UTF-8"
    if is_utf8(data):
        return None, "字节符合 UTF-8"

    text = None
    matches = []
    for encoding in GB_ENCODINGS:
        try:
            decoded = data.decode(encoding)
        except UnicodeDecodeError:
            continue
        if text is not None and decoded != text:
            return None, "GB 系候选解码结果不同，请用模式 A 指定原编码"
        text = decoded
        matches.append(encoding.upper())

    if text is None:
        return None, "无法按 GB 系编码完整解码"
    return text, "/".join(matches)


def write_new_file(destination, data):
    output = destination.open("xb")
    try:
        with output:
            output.write(data)
    except BaseException:
        destination.unlink()
        raise


def convert_directory(directory, suffixes, source_encoding, output_encoding):
    program = Path(__file__).resolve()
    program_files = {program, program.with_suffix(".bat"), program.with_suffix(".sh")}
    converted = skipped = failed = 0

    for source in sorted(directory.iterdir()):
        if source.suffix.casefold() not in suffixes or source in program_files:
            continue
        if not source.is_file():
            continue

        destination = source.with_name(source.stem + OUTPUT_MARKER + source.suffix)
        try:
            if destination.exists():
                raise FileExistsError(destination)

            data = source.read_bytes()
            if source_encoding is None:
                text, detail = detect_gb_text(data)
            elif source.stem.casefold().endswith(OUTPUT_MARKER) and is_utf8(data):
                text, detail = None, "主文件名以 _tf 结尾且内容已为 UTF-8"
            else:
                text = data.decode(source_encoding)
                detail = source_encoding.upper()

            if text is None:
                print(f"[跳过] {source.name}（{detail}）")
                skipped += 1
                continue

            # 二进制读写避免平台自动转换换行符。
            write_new_file(destination, text.encode(output_encoding))
        except FileExistsError:
            print(f"[跳过] {source.name}（目标已存在，{destination.name}）")
            skipped += 1
        except UnicodeDecodeError as error:
            print(f"[失败] {source.name}（无法按 {error.encoding.upper()} 解码，字节偏移 {error.start}）")
            failed += 1
        except (OSError, UnicodeEncodeError) as error:
            print(f"[失败] {source.name}（{error}）")
            failed += 1
        else:
            print(f"[转换] {source.name} -> {destination.name}（{detail}）")
            converted += 1

    if converted + skipped + failed == 0:
        print("当前目录没有符合条件的文件。")
    print(f"完成。已转换 {converted} 个，跳过 {skipped} 个，失败 {failed} 个。")
    return 1 if failed else 0


def wait_for_key():
    if not sys.stdin.isatty():
        return

    prompt = "按任意键退出…"
    if os.name == "nt":
        import msvcrt

        print(prompt, end="", flush=True)
        msvcrt.getwch()
    else:
        import termios
        import tty

        fd = sys.stdin.fileno()
        previous_settings = termios.tcgetattr(fd)
        try:
            tty.setraw(fd)
            print(prompt, end="", flush=True)
            os.read(fd, 1)
        finally:
            termios.tcsetattr(fd, termios.TCSAFLUSH, previous_settings)
    print()


def main():
    directory = Path.cwd()
    windows = os.name == "nt"
    output_encoding = "utf-8-sig" if windows else "utf-8"
    print(f"当前目录 {directory}")
    print("仅处理当前目录中的文件。原文件保留，结果另存为 原名称_tf.扩展名。")
    print(f"输出为 UTF-8（{'带' if windows else '无'} BOM）。已有同名目标会跳过。")
    print("A  手动选择原编码和文件后缀，直接按所选编码转换。")
    print("B  自动探测 .cpp、.c、.py、.txt、.md。已是 UTF-8 或 GB 候选解码有歧义时会跳过。")
    print("Q  退出。")

    while True:
        mode = input("选择模式（A / B / Q）> ").strip().upper()
        if mode == "Q":
            return 0
        if mode == "A":
            encoding = prompt_for_encoding()
            suffixes = prompt_for_suffixes()
            break
        if mode == "B":
            encoding = None
            suffixes = AUTO_SUFFIXES
            break
        print("请输入 A、B 或 Q。")

    status = convert_directory(directory, suffixes, encoding, output_encoding)
    wait_for_key()
    return status


if __name__ == "__main__":
    try:
        sys.exit(main())
    except EOFError:
        print("\n输入结束，已退出。")
        sys.exit(1)
    except KeyboardInterrupt:
        print("\n操作已中断。")
        sys.exit(130)
    except OSError as error:
        print(f"[失败] {error}", file=sys.stderr)
        sys.exit(1)
