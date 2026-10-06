#!/usr/bin/env python3
"""Audit Kbuild's saved compiler commands without executing them."""
import collections
import csv
import pathlib
import shlex
import re
import subprocess
import sys


def stages(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=';&|')
    lexer.whitespace_split = True
    lexer.commenters = ''
    stage = []
    for token in lexer:
        if token in (';', '&&', '||', '|'):
            if stage:
                yield stage
            stage = []
        else:
            stage.append(token)
    if stage:
        yield stage


def arguments(tokens):
    result = []
    iterator = iter(tokens)
    for token in iterator:
        if token in ('-C', '-Z'):
            token += next(iterator)
        elif token == '--target':
            token += '=' + next(iterator)
        result.append(token)
    return result


def last(args, prefix):
    return next((arg for arg in reversed(args) if arg.startswith(prefix)), '')


def llvm_arguments(args, tool):
    result = []
    iterator = iter(args)
    for token in iterator:
        if tool == 'rustc' and token.startswith('-Cllvm-args='):
            result.extend(shlex.split(token.removeprefix('-Cllvm-args=')))
        elif tool == 'clang' and token == '-mllvm':
            result.append(next(iterator))
        elif tool == 'clang' and token.startswith('-mllvm='):
            result.append(token.removeprefix('-mllvm='))
    return result


def audit_bitcode(root, toolchain, tune, report):
    rows = []
    for relative in ('rust/helpers/helpers.bc', 'rust/kernel.bc', 'rust/kernel.m.bc'):
        ir = subprocess.check_output([str(pathlib.Path(toolchain) / 'bin/llvm-dis'),
                                      str(root / relative), '-o', '-'], text=True)
        attrs = dict(re.findall(r'^attributes #(\d+) = \{(.*)\}$', ir, re.M))
        definitions = re.findall(r'^define .*?#(\d+)\b', ir, re.M)
        if not definitions:
            raise SystemExit(relative + ': no attributed function definitions')
        for index in sorted(set(definitions), key=int):
            attribute = attrs[index]
            models = re.findall(r'"tune-cpu"="([^"]+)"', attribute)
            if models != [tune]:
                raise SystemExit(relative + ': missing effective LLVM tune-cpu')
            features = re.search(r'"target-features"="([^"]+)"', attribute)
            if not features:
                raise SystemExit(relative + ': missing LLVM target-features')
            effective = {flag[1:]: flag[0] for flag in features[1].split(',')}
            if any(effective.get(feature) != '-' for feature in ('neon', 'fp-armv8', 'sve')):
                raise SystemExit(relative + ': FP/NEON/SVE enabled in ordinary kernel bitcode')
            if effective.get('strict-align') == '+':
                raise SystemExit(relative + ': strict-align retained in ordinary kernel bitcode')
            if relative == 'rust/kernel.bc' and effective.get('strict-align') != '-':
                raise SystemExit(relative + ': missing effective Rust -strict-align')
            # Clang and Rust handle SME dependencies differently. Record its
            # effective state; do not rewrite the compiler's attributes.
            rows.append([relative, index, models[0], effective.get('sme', 'unset'), features[1]])
    with pathlib.Path(report).open('w') as stream:
        writer = csv.writer(stream, delimiter='\t', lineterminator='\n')
        writer.writerow(['bitcode', 'attributes', 'tune', 'sme', 'target_features'])
        writer.writerows(rows)


def main():
    (root, profile, c_arch, tune, rust_features, report,
     toolchain, layout_flags, core_threads) = sys.argv[1:10]
    scope = sys.argv[10:]
    if scope not in ([], ['--preflight']):
        raise SystemExit('unexpected compiler audit scope')
    root = pathlib.Path(root)
    expected_layout = shlex.split(layout_flags)
    rows, issues = [], []
    counts = collections.Counter()
    required = {
        ('kernel/sched/.fair.o.cmd', 'clang-c'),
        ('mm/.filemap.o.cmd', 'clang-c'),
        ('fs/f2fs/.node.o.cmd', 'clang-c'),
        ('rust/helpers/.helpers.bc.cmd', 'clang-c'),
        ('rust/.core.o.cmd', 'rustc'),
        ('rust/.kernel.o.cmd', 'rustc'),
        ('rust/.kernel.o.cmd', 'clang-bitcode'),
    }
    # Fixed Kbuild paths deliberately compiled without AutoFDO. Bitcode has
    # already received the profile in its Rust/C producer, before llvm-link.
    no_profile_dirs = ('arch/arm64/kernel/pi/', 'arch/arm64/kernel/vdso/',
                       'arch/arm64/kvm/hyp/', 'drivers/firmware/efi/libstub/')
    no_profile_files = {'..vmlinux.export.o.cmd', 'init/.version-timestamp.o.cmd',
                        'scripts/mod/.empty.o.cmd'}
    # Preflight has rebuilt only these producers. Other saved commands still
    # describe the previous build and are audited after Image/modules finish.
    if scope:
        paths = {root / path for path, _ in required}
    else:
        paths = root.rglob('.*.cmd')
    for path in sorted(paths):
        relative = path.relative_to(root).as_posix()
        for line in path.read_text(errors='replace').splitlines():
            if not line.startswith(('savedcmd_', 'cmd_')) or ' := ' not in line:
                continue
            for tokens in stages(line.split(' := ', 1)[1]):
                compiler = next((i for i, token in enumerate(tokens)
                                 if pathlib.Path(token).name in ('clang', 'rustc')), None)
                if compiler is None:
                    continue
                tool = pathlib.Path(tokens[compiler]).name
                args = arguments(tokens[compiler + 1:])
                target = last(args, '--target=').removeprefix('--target=') or 'host'
                source = next((arg for arg in args if arg.endswith(('.c', '.S', '.bc', '.rs'))), '')
                if tool == 'clang' and '-c' not in args and '-emit-llvm' not in args:
                    continue
                kind = 'rustc' if tool == 'rustc' else ('clang-asm' if source.endswith('.S')
                        else 'clang-bitcode' if source.endswith('.bc') else 'clang-c')
                arm64 = target.startswith('aarch64')
                counts[(kind, 'arm64' if arm64 else target)] += 1
                isa = last(args, '-Ctarget-feature=' if tool == 'rustc' else '-march=')
                model = last(args, '-Ztune-cpu=' if tool == 'rustc' else '-mtune=')
                sample = last(args, '-Zprofile-sample-use=' if tool == 'rustc' else '-fprofile-sample-use=')
                llvm = llvm_arguments(args, tool)
                layout = [last(llvm, prefix) for prefix in
                          ('-enable-ext-tsp-block-placement=', '-ext-tsp-apply-without-profile=')]
                threads = last(args, '-Zthreads=') if tool == 'rustc' else ''
                if arm64 and kind != 'clang-asm':
                    expected = [('-Ctarget-cpu=', 'generic'), ('-Ztune-cpu=', tune),
                                ('-Ctarget-feature=', rust_features)] if tool == 'rustc' else [
                                ('-march=', c_arch), ('-mtune=', tune)]
                    for prefix, value in expected:
                        if last(args, prefix) != prefix + value:
                            issues.append(relative + ': missing or overridden ' + prefix + value)
                    if tool == 'rustc' and rust_features.split(',')[-1] != '-neon':
                        issues.append(relative + ': missing final -neon')
                    if tool == 'rustc' and target != 'aarch64-unknown-none-softfloat':
                        issues.append(relative + ': missing softfloat ABI')
                    if tool == 'clang' and last(args, '-mcpu='):
                        issues.append(relative + ': unexpected -mcpu')
                    if layout != expected_layout:
                        issues.append(relative + ': missing or overridden profile-only ExtTSP flags')
                    if tool == 'rustc':
                        expected_threads = ('-Zthreads=' + core_threads
                                            if relative == 'rust/.core.o.cmd' else '')
                        if threads != expected_threads:
                            issues.append(relative + ': incorrect core-only frontend parallelism')
                        if last(args, '-Ccodegen-units=') != '-Ccodegen-units=1':
                            issues.append(relative + ': codegen-units must remain 1')
                    if relative == 'arch/arm64/kernel/pi/.map_range.o.cmd':
                        alignment = next((arg for arg in reversed(args) if arg in
                                          ('-mstrict-align', '-mno-strict-align')), '')
                        if alignment != '-mstrict-align':
                            issues.append(relative + ': early boot strict alignment lost')
                    skip_profile = (kind == 'clang-bitcode' or relative in no_profile_files
                                    or relative.startswith(no_profile_dirs))
                    prefix = '-Zprofile-sample-use=' if tool == 'rustc' else '-fprofile-sample-use='
                    if (sample or not skip_profile) and sample != prefix + profile:
                        issues.append(relative + ': missing or overridden AutoFDO profile')
                    required.discard((relative, kind))
                    if (relative, kind) in {('kernel/sched/.fair.o.cmd', 'clang-c'),
                                           ('mm/.filemap.o.cmd', 'clang-c'),
                                           ('fs/f2fs/.node.o.cmd', 'clang-c'),
                                           ('rust/helpers/.helpers.bc.cmd', 'clang-c'),
                                           ('rust/.kernel.o.cmd', 'clang-bitcode')}:
                        if '-mgeneral-regs-only' not in args or '-mno-general-regs-only' in args:
                            issues.append(relative + ': missing GPR restriction')
                elif (model or isa in ('-march=' + c_arch, '-Ctarget-feature=' + rust_features)
                      or any(layout) or threads):
                    issues.append(relative + ': SM8850 flags leaked into ' + target + '/' + kind)
                rows.append([relative, kind, target, source, isa, model, sample,
                             str('-mgeneral-regs-only' in args), *layout, threads, shlex.join(tokens)])
    issues += ['missing required compiler stage: ' + path + '/' + kind
               for path, kind in sorted(required)]
    with pathlib.Path(report).open('w') as stream:
        writer = csv.writer(stream, delimiter='\t', lineterminator='\n')
        writer.writerow(['object', 'stage', 'target', 'source', 'effective_isa',
                         'effective_tune', 'profile', 'gpr_only', 'exttsp',
                         'exttsp_without_profile', 'frontend_threads', 'command'])
        writer.writerows(rows)
    for (kind, target), count in sorted(counts.items()):
        print(kind, target, count)
    if issues:
        raise SystemExit('\n'.join(issues))
    audit_bitcode(root, toolchain, tune,
                  pathlib.Path(report).with_name('llvm-target-attributes.current.tsv'))


if __name__ == '__main__':
    main()
