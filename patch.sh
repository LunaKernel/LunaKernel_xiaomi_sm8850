#!/usr/bin/env bash
#
# patch.sh - project-owned direct kernel tuning/modification stage
#
set -euo pipefail

die() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }
log_info() { printf '[INFO] %s\n' "$1"; }
log_step() { printf '[STEP] %s\n' "$1"; }
log_success() { printf '[OK] %s\n' "$1"; }

load_env_file() {
    local env_file="$1"
    local had_allexport=0
    [ -f "${env_file}" ] || return
    case "$-" in *a*) had_allexport=1 ;; esac
    set -a
    . "${env_file}"
    [ "${had_allexport}" = "1" ] || set +a
}

sanitize_path_component() { printf '%s' "$1" | LC_ALL=C tr -cs 'A-Za-z0-9._-' '_'; }
resolve_workspace_path() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "${HOST_WORKSPACE_DIR}" "$1" ;; esac; }

orbctl_run() { local cmd=(orbctl run); [ -z "${ORB_MACHINE:-}" ] || cmd+=(-m "${ORB_MACHINE}"); "${cmd[@]}" "$@"; }
orbctl_run_host_path() { local cmd=(orbctl run -p); [ -z "${ORB_MACHINE:-}" ] || cmd+=(-m "${ORB_MACHINE}"); "${cmd[@]}" "$@"; }

sync_control_files_to_orb() {
    local items="init.sh patch.sh patch_external.sh build.sh patches"
    [ ! -f "${HOST_WORKSPACE_DIR}/.env" ] || items="${items} .env"
    orbctl_run_host_path -w "${HOST_WORKSPACE_DIR}" sh -lc "set -e; target=\"\$HOME/${ORB_LINUX_WORKSPACE}\"; mkdir -p \"\$target\"; tar -cf - ${items} | tar -xf - -C \"\$target\""
}

run_in_orb_if_needed() {
    case "$(uname -s)" in
        Linux) return ;;
        Darwin)
            command -v orbctl >/dev/null 2>&1 || die "当前是 macOS，请启动 OrbStack。"
            sync_control_files_to_orb
            if orbctl_run sh -lc "cd \"\$HOME/${ORB_LINUX_WORKSPACE}\" && exec bash ./patch.sh \"\$@\"" sh "$@"; then exit 0; else exit $?; fi
            ;;
        *) die "不支持的操作系统" ;;
    esac
}

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
HOST_WORKSPACE_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd -P)"
load_env_file "${HOST_WORKSPACE_DIR}/.env"
WORKSPACE_NAME="$(sanitize_path_component "$(basename "${HOST_WORKSPACE_DIR}")")"
ORB_LINUX_ROOT="${ORB_LINUX_ROOT:-.cache/xiaomi_kernel_build}"
ORB_LINUX_WORKSPACE="${ORB_LINUX_ROOT%/}/${WORKSPACE_NAME:-workspace}/workspace"
run_in_orb_if_needed "$@"

COMMON_DIR="$(resolve_workspace_path "${COMMON_SOURCE_DIR:-sources/aosp_common_6.12.23_r57}")"
[ -d "${COMMON_DIR}/.git" ] || die "GKI common 未初始化，请先运行 ./init.sh"
[ "$(git -C "${COMMON_DIR}" rev-parse HEAD)" = "${COMMON_COMMIT:-a82fc641d6d2c687802606190c0a8c33a4242201}" ] || die "GKI common pin 不匹配"

AOSP_BACKPORT_AUDIT_DIR="$(resolve_workspace_path "${AOSP_BACKPORT_AUDIT_SOURCE_DIR:-sources/aosp_common_backport_audit}")"
LINUX_STABLE_AUDIT_DIR="$(resolve_workspace_path "${LINUX_STABLE_AUDIT_SOURCE_DIR:-sources/linux_stable_6.12_audit}")"
ENABLE_FUTEX_EXITING_POINTER_FIX="${ENABLE_FUTEX_EXITING_POINTER_FIX:-0}"
FUTEX_EXITING_POINTER_STABLE_COMMIT="${FUTEX_EXITING_POINTER_STABLE_COMMIT:-7475dfad10a05a5bfadebf5f2499bd61b19ed293}"
FUTEX_EXITING_POINTER_PATCH_ID="${FUTEX_EXITING_POINTER_PATCH_ID:-419d86818387f958327185e62d1581e20b357a1d}"
ENABLE_FUTEX_REQUEUE_PI_LOCKUP_FIX="${ENABLE_FUTEX_REQUEUE_PI_LOCKUP_FIX:-0}"
FUTEX_REQUEUE_PI_LOCKUP_STABLE_COMMIT="${FUTEX_REQUEUE_PI_LOCKUP_STABLE_COMMIT:-0aacb6d18f76552e3e0ee25d9f40d21b3486f4cf}"
FUTEX_REQUEUE_PI_LOCKUP_PATCH_ID="${FUTEX_REQUEUE_PI_LOCKUP_PATCH_ID:-88d19e4a03bfc1fdc6b126a65489e9d62eae2780}"
ENABLE_F2FS_ACL_ENTRY_BOUNDS_FIX="${ENABLE_F2FS_ACL_ENTRY_BOUNDS_FIX:-0}"
F2FS_ACL_ENTRY_BOUNDS_STABLE_COMMIT="${F2FS_ACL_ENTRY_BOUNDS_STABLE_COMMIT:-aba4f94ac1832c7299c33e1b4fe5f87eef6dc8f1}"
F2FS_ACL_ENTRY_BOUNDS_PATCH_ID="${F2FS_ACL_ENTRY_BOUNDS_PATCH_ID:-3021795cf81293828302c01bb7d52bb4d52a7259}"
ENABLE_F2FS_LISTXATTR_BOUNDS_FIX="${ENABLE_F2FS_LISTXATTR_BOUNDS_FIX:-0}"
F2FS_LISTXATTR_BOUNDS_STABLE_COMMIT="${F2FS_LISTXATTR_BOUNDS_STABLE_COMMIT:-7dd01f7d0291583e3e5420c95c7d584e114899bd}"
F2FS_LISTXATTR_BOUNDS_PATCH_ID="${F2FS_LISTXATTR_BOUNDS_PATCH_ID:-daaf1f38e2ef4939e6981e7a563c1a488225a11c}"
ENABLE_BLKCG_RSTAT_RELEASE_FIX="${ENABLE_BLKCG_RSTAT_RELEASE_FIX:-0}"
BLKCG_RSTAT_RELEASE_STABLE_COMMIT="${BLKCG_RSTAT_RELEASE_STABLE_COMMIT:-bbebd9425cad3573d1527441753899b926525a0f}"
BLKCG_RSTAT_RELEASE_PATCH_ID="${BLKCG_RSTAT_RELEASE_PATCH_ID:-5149120b23c377e425b11bfdcb1933e39245a1c7}"
ENABLE_BINDER_TRANSACTION_LIFETIME_FIX="${ENABLE_BINDER_TRANSACTION_LIFETIME_FIX:-0}"
BINDER_THREAD_RELEASE_STABLE_COMMIT="${BINDER_THREAD_RELEASE_STABLE_COMMIT:-e63032dc715026a96bcaa13d375a8e15c91caa84}"
BINDER_THREAD_RELEASE_PATCH_ID="${BINDER_THREAD_RELEASE_PATCH_ID:-bf97fd8b894461ca62445978f4f6422c736611b3}"
BINDER_FREE_TRANSACTION_STABLE_COMMIT="${BINDER_FREE_TRANSACTION_STABLE_COMMIT:-d45ef513eed1abebfec90c3cfb6ae50c2a4182db}"
BINDER_FREE_TRANSACTION_PATCH_ID="${BINDER_FREE_TRANSACTION_PATCH_ID:-5c23abbc83c1a297d19eb039610151fb377ea188}"
BINDER_TRANSACTION_LIFETIME_PATCH="${HOST_WORKSPACE_DIR}/${BINDER_TRANSACTION_LIFETIME_PATCH:-patches/backports/binder-transaction-lifetime-6.12.23.patch}"
BINDER_TRANSACTION_LIFETIME_PATCH_SHA256="${BINDER_TRANSACTION_LIFETIME_PATCH_SHA256:-d3d428c044437c216bf75bbe45e01cd74e780f4685586c08a2e6b3d1d2ac83d3}"
BINDER_TRANSACTION_LIFETIME_PATCH_ID="${BINDER_TRANSACTION_LIFETIME_PATCH_ID:-7d9a01598e58b1f513fcfbe481dc682bd62c1f5c}"
ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX="${ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX:-0}"
F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT="${F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT:-44480f7e3f8369671452c0d262831c51aa5a9c20}"
F2FS_FOREGROUND_GC_DEADLOCK_PATCH_ID="${F2FS_FOREGROUND_GC_DEADLOCK_PATCH_ID:-8d86d1f0ff47ad109628af8462bd4506c81dd4f6}"
F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT="${F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT:-b885c7783c19c36c7bf899492a0bffcd68afa8c7}"
F2FS_GC_MERGE_DEADLOCK_PATCH_ID="${F2FS_GC_MERGE_DEADLOCK_PATCH_ID:-f1e7da7bf78fadbfd5f41ae8f1d1b196ee96b98d}"
ENABLE_F2FS_ATOMIC_INODE_UAF_FIX="${ENABLE_F2FS_ATOMIC_INODE_UAF_FIX:-0}"
F2FS_ATOMIC_INODE_UAF_STABLE_COMMIT="${F2FS_ATOMIC_INODE_UAF_STABLE_COMMIT:-56038756aae68312df00d4aa1d97e51ef3aca725}"
F2FS_ATOMIC_INODE_UAF_PATCH_ID="${F2FS_ATOMIC_INODE_UAF_PATCH_ID:-fcedf0927ac32abbbc60de374663dc3fec18869d}"
ENABLE_UFS_RUNTIME_PM_ERROR_RECOVERY_FIX="${ENABLE_UFS_RUNTIME_PM_ERROR_RECOVERY_FIX:-0}"
UFS_RUNTIME_SUSPEND_DEADLOCK_AOSP_COMMIT="${UFS_RUNTIME_SUSPEND_DEADLOCK_AOSP_COMMIT:-7ef00d3457d8c9cee0915ee0edff247031c36e0c}"
UFS_RUNTIME_SUSPEND_DEADLOCK_PATCH_ID="${UFS_RUNTIME_SUSPEND_DEADLOCK_PATCH_ID:-d50c32d5918d030180b869f67a0ccd412b62209e}"
UFS_ERROR_HANDLER_HOST_SEM_AOSP_COMMIT="${UFS_ERROR_HANDLER_HOST_SEM_AOSP_COMMIT:-459c818f8b5a562c34a27b915fae53792fa82a71}"
UFS_ERROR_HANDLER_HOST_SEM_PATCH_ID="${UFS_ERROR_HANDLER_HOST_SEM_PATCH_ID:-32e05876eba86a6181f7f2cbc538f2fb73e63528}"
UFS_ERROR_HANDLER_WLUN_AOSP_COMMIT="${UFS_ERROR_HANDLER_WLUN_AOSP_COMMIT:-a460b437af44c3317a57e637455ee891d0ee0352}"
UFS_ERROR_HANDLER_WLUN_PATCH_ID="${UFS_ERROR_HANDLER_WLUN_PATCH_ID:-b4ec70973aaeef49650271cffd241533d63fac57}"
UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH="${HOST_WORKSPACE_DIR}/${UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH:-patches/backports/ufs-runtime-pm-error-recovery-6.12.23.patch}"
UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH_SHA256="${UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH_SHA256:-2b29d2d00f657e518d28361c095e311fbd8cbb31bc6275f641c85587a164eb2a}"
UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH_ID="${UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH_ID:-35f93b5023c3f14d3616f1a3afc236f36c84b11f}"
ENABLE_TIMER_BASE_FAST_PATH="${ENABLE_TIMER_BASE_FAST_PATH:-0}"
TIMER_BASE_FAST_PATH_COMMIT="${TIMER_BASE_FAST_PATH_COMMIT:-3ec955713d9617059d2fc8f2816d0b95ace72256}"
TIMER_BASE_FAST_PATH_PATCH_ID="${TIMER_BASE_FAST_PATH_PATCH_ID:-68dca003ed5b13fb40d3b777155c6568438563ef}"
ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH="${ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH:-0}"
F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT="${F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT:-d860974a7e38d35e9e2c4dc8a9f4223b38b6ad99}"
F2FS_DIO_OVERWRITE_FAST_PATH_PATCH_ID="${F2FS_DIO_OVERWRITE_FAST_PATH_PATCH_ID:-fec231f96375f0622cf9bd9427ef2baf5614ac03}"
ENABLE_EAS_CPUMASK_FAST_PATH="${ENABLE_EAS_CPUMASK_FAST_PATH:-0}"
EAS_CPUMASK_FAST_PATH_COMMIT="${EAS_CPUMASK_FAST_PATH_COMMIT:-ff1de90dd7a69ef43586683535ad87ab899a1214}"
EAS_CPUMASK_FAST_PATH_PATCH_ID="${EAS_CPUMASK_FAST_PATH_PATCH_ID:-26fce9484b896c6e1c89b30faf18e6790b2a005d}"
ENABLE_BLK_WBT_DONE_FAST_PATH="${ENABLE_BLK_WBT_DONE_FAST_PATH:-0}"
BLK_WBT_DONE_FAST_PATH_COMMIT="${BLK_WBT_DONE_FAST_PATH_COMMIT:-d8b96a79622e03813c221450498ca9742704ebf2}"
BLK_WBT_DONE_FAST_PATH_PATCH_ID="${BLK_WBT_DONE_FAST_PATH_PATCH_ID:-097d27325d53feb894b26bb0c7e152fca314e7b9}"
ENABLE_F2FS_OPEN_FAST_PATH="${ENABLE_F2FS_OPEN_FAST_PATH:-0}"
F2FS_OPEN_FAST_PATH_COMMIT="${F2FS_OPEN_FAST_PATH_COMMIT:-f6e898257b3d6a3a52d4bff5cec6237eebe1ce7d}"
F2FS_OPEN_FAST_PATH_PATCH_ID="${F2FS_OPEN_FAST_PATH_PATCH_ID:-685b528beff90bac24b8f54e12238442363a80df}"
ENABLE_MEMCG_RSTAT_FAST_PATH="${ENABLE_MEMCG_RSTAT_FAST_PATH:-0}"
MEMCG_RSTAT_FAST_PATH_COMMIT="${MEMCG_RSTAT_FAST_PATH_COMMIT:-60cada258dfe3694e15c4539259173c37bd5f1fe}"
MEMCG_RSTAT_FAST_PATH_PATCH_ID="${MEMCG_RSTAT_FAST_PATH_PATCH_ID:-5b12701394b4f6a128f5456e3bd8fed4f8740c27}"
ENABLE_TCP_RECV_MSTAMP_FAST_PATH="${ENABLE_TCP_RECV_MSTAMP_FAST_PATH:-0}"
TCP_RECV_MSTAMP_FAST_PATH_COMMIT="${TCP_RECV_MSTAMP_FAST_PATH_COMMIT:-0ae1ac7335ca2328c42fbbe2b71bc9c3fc8e65d9}"
TCP_RECV_MSTAMP_FAST_PATH_PATCH_ID="${TCP_RECV_MSTAMP_FAST_PATH_PATCH_ID:-66387ee17b01507a8f2a2b6537c9f7e22c86b509}"
ENABLE_F2FS_MERGE_PAGE_BIO_UAF_FIX="${ENABLE_F2FS_MERGE_PAGE_BIO_UAF_FIX:-0}"
F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT="${F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT:-f2f676a2f21637b39f7f2be2f6137c1d9570d3e7}"
F2FS_MERGE_PAGE_BIO_UAF_FIX_PATCH_ID="${F2FS_MERGE_PAGE_BIO_UAF_FIX_PATCH_ID:-ae11e76a9f7b489004102506a0896e0894ae681f}"
ENABLE_GUNYAH_CLEAN_RESOURCES_UAF_FIX="${ENABLE_GUNYAH_CLEAN_RESOURCES_UAF_FIX:-0}"
GUNYAH_CLEAN_RESOURCES_UAF_FIX_COMMIT="${GUNYAH_CLEAN_RESOURCES_UAF_FIX_COMMIT:-e5a17398e40d988ce7e9c79259eb8b08b5377b43}"
GUNYAH_CLEAN_RESOURCES_UAF_FIX_PATCH_ID="${GUNYAH_CLEAN_RESOURCES_UAF_FIX_PATCH_ID:-b422a66e01ad0e4046dedafc81785fc8b4a9ff57}"
ENABLE_IDLETIMER_DESTROY_UAF_FIX="${ENABLE_IDLETIMER_DESTROY_UAF_FIX:-0}"
IDLETIMER_DESTROY_UAF_FIX_COMMIT="${IDLETIMER_DESTROY_UAF_FIX_COMMIT:-9317fe019b5be27e888f02629a3de1f4d78cb1aa}"
IDLETIMER_DESTROY_UAF_FIX_PATCH_ID="${IDLETIMER_DESTROY_UAF_FIX_PATCH_ID:-2e6c62f1168d9eb5163373eac35801caa4d4a631}"
ENABLE_EVENTPOLL_RCU_UAF_FIX="${ENABLE_EVENTPOLL_RCU_UAF_FIX:-0}"
EVENTPOLL_RCU_UAF_FIX_COMMIT="${EVENTPOLL_RCU_UAF_FIX_COMMIT:-5b1173b165421561db29f30afc7e97d940a398a9}"
EVENTPOLL_RCU_UAF_FIX_PATCH_ID="${EVENTPOLL_RCU_UAF_FIX_PATCH_ID:-a5abf8e11ad85b58f2924d8bd693b8b644462f6a}"
ENABLE_CGROUP_KERNFS_UAF_FIX="${ENABLE_CGROUP_KERNFS_UAF_FIX:-0}"
CGROUP_KERNFS_UAF_FIX_COMMIT="${CGROUP_KERNFS_UAF_FIX_COMMIT:-993047031c9fcb7f4a58389692e844f7be423cc7}"
CGROUP_KERNFS_UAF_FIX_PATCH_ID="${CGROUP_KERNFS_UAF_FIX_PATCH_ID:-7fb683b637d0db664c6c37667692c27127a28dd1}"
ENABLE_F2FS_SYNC_INODE_META_UAF_FIX="${ENABLE_F2FS_SYNC_INODE_META_UAF_FIX:-0}"
F2FS_SYNC_INODE_META_UAF_FIX_COMMIT="${F2FS_SYNC_INODE_META_UAF_FIX_COMMIT:-dea243f58a8391e76f42ad5eb59ff210519ee772}"
F2FS_SYNC_INODE_META_UAF_FIX_PATCH_ID="${F2FS_SYNC_INODE_META_UAF_FIX_PATCH_ID:-41eeded4f38919c5bffa8aef0c8b9b2468346b9d}"
ENABLE_TIMER_SHUTDOWN_SYNC_RACE_FIX="${ENABLE_TIMER_SHUTDOWN_SYNC_RACE_FIX:-0}"
TIMER_SHUTDOWN_SYNC_RACE_FIX_COMMIT="${TIMER_SHUTDOWN_SYNC_RACE_FIX_COMMIT:-176725f4848376530a0f0da9023f956afcc33585}"
TIMER_SHUTDOWN_SYNC_RACE_FIX_PATCH_ID="${TIMER_SHUTDOWN_SYNC_RACE_FIX_PATCH_ID:-e528717d3d19cb12b0d9ac96781075350fdf4dae}"
ENABLE_FUTEX_REQUEUE_PI_UAF_FIX="${ENABLE_FUTEX_REQUEUE_PI_UAF_FIX:-0}"
FUTEX_REQUEUE_PI_UAF_FIX_COMMIT="${FUTEX_REQUEUE_PI_UAF_FIX_COMMIT:-a170b9c0dde83312b8b58ccc91509c7c15711641}"
FUTEX_REQUEUE_PI_UAF_FIX_PATCH_ID="${FUTEX_REQUEUE_PI_UAF_FIX_PATCH_ID:-8a1bf4596581bd162f4acb909b7ee859ca2c7afa}"
ENABLE_PAGE_POOL_DESTROY_RACE_FIX="${ENABLE_PAGE_POOL_DESTROY_RACE_FIX:-0}"
PAGE_POOL_DESTROY_RACE_FIX_COMMIT="${PAGE_POOL_DESTROY_RACE_FIX_COMMIT:-e869a85acc2e60dc554579b910826a4919d8cd98}"
PAGE_POOL_DESTROY_RACE_FIX_PATCH_ID="${PAGE_POOL_DESTROY_RACE_FIX_PATCH_ID:-dad3ca58feaaae658e77c9e001250fed18853b1e}"
ENABLE_CONNTRACK_UNCONFIRMED_RACE_FIX="${ENABLE_CONNTRACK_UNCONFIRMED_RACE_FIX:-0}"
CONNTRACK_UNCONFIRMED_RACE_FIX_COMMIT="${CONNTRACK_UNCONFIRMED_RACE_FIX_COMMIT:-fc38c249c622ff5e3011b8845fd49dbfd9289afc}"
CONNTRACK_UNCONFIRMED_RACE_FIX_PATCH_ID="${CONNTRACK_UNCONFIRMED_RACE_FIX_PATCH_ID:-37b80fce84a874c3917935828ffbb6b74b3a8ee6}"
ENABLE_EROFS_DIR_TAIL_OOB_FIX="${ENABLE_EROFS_DIR_TAIL_OOB_FIX:-0}"
EROFS_DIR_TAIL_OOB_FIX_COMMIT="${EROFS_DIR_TAIL_OOB_FIX_COMMIT:-48b27a955d22391c7f30169fa7b6b2e1977f1ce4}"
EROFS_DIR_TAIL_OOB_FIX_PATCH_ID="${EROFS_DIR_TAIL_OOB_FIX_PATCH_ID:-86095c51c9af49433ddbba4d32f194c2d3a7a6da}"
ENABLE_EXT4_XATTR_OOB_FIX="${ENABLE_EXT4_XATTR_OOB_FIX:-0}"
EXT4_XATTR_OOB_FIX_COMMIT="${EXT4_XATTR_OOB_FIX_COMMIT:-5a5314d2387633a272a04d1bd8727f99058e4e68}"
EXT4_XATTR_OOB_FIX_PATCH_ID="${EXT4_XATTR_OOB_FIX_PATCH_ID:-98a7513db9abe6f0c8c0713c9e03bca09d99af6c}"
ENABLE_IPV6_MLD_UAF_FIX="${ENABLE_IPV6_MLD_UAF_FIX:-0}"
IPV6_MLD_UAF_FIX_COMMIT="${IPV6_MLD_UAF_FIX_COMMIT:-791c91dc7a9dfb2457d5e29b8216a6484b9c4b40}"
IPV6_MLD_UAF_FIX_PATCH_ID="${IPV6_MLD_UAF_FIX_PATCH_ID:-1358ebc3d619657f50c2f0f50f5408f60ea5b732}"
ENABLE_RTMUTEX_WAITER_ENQUEUE_FIX="${ENABLE_RTMUTEX_WAITER_ENQUEUE_FIX:-0}"
RTMUTEX_WAITER_ENQUEUE_FIX_COMMIT="${RTMUTEX_WAITER_ENQUEUE_FIX_COMMIT:-202a62288cb6884f0bdcea8a8d47a1a8c4d3e143}"
RTMUTEX_WAITER_ENQUEUE_FIX_PATCH_ID="${RTMUTEX_WAITER_ENQUEUE_FIX_PATCH_ID:-0d78a126f83be68e6f97baae61550baacc3a2ecc}"
RTMUTEX_FIX_STACK_PATCH_ID="${RTMUTEX_FIX_STACK_PATCH_ID:-91738174f7b3c38cc0cfc8f7b2157aa1fb648a2a}"
ENABLE_STAGE5_RTMUTEX_FIX="${ENABLE_STAGE5_RTMUTEX_FIX:-0}"
STAGE5_RTMUTEX_FIX_COMMIT="${STAGE5_RTMUTEX_FIX_COMMIT:-e7d9bd94fbdbf9842ea6f1b6d5af45758e87e3d6}"
STAGE5_RTMUTEX_FIX_PATCH_ID="${STAGE5_RTMUTEX_FIX_PATCH_ID:-bd48afa70647e92db0e44335fbe75d2b520671a6}"
ENABLE_UNICODE_IGNORABLE_FIX="${ENABLE_UNICODE_IGNORABLE_FIX:-0}"
UNICODE_FIX_COMMIT="${UNICODE_FIX_COMMIT:-425419e5b2a8c88096b8bbc61d8865600d1a91c0}"
UNICODE_FIX_PATCH_ID="${UNICODE_FIX_PATCH_ID:-8bad10993f9d6df5a0130e8394608f4550904bbd}"
UNICODE_FIX_PATCH="${HOST_WORKSPACE_DIR}/${UNICODE_FIX_PATCH:-patches/unicode/aosp-6.12.23-default-ignorable-compat.patch}"
UNICODE_FIX_PATCH_SHA256="${UNICODE_FIX_PATCH_SHA256:-7bc109d9858c14c78dfdbaadd4be3ff16188e919ee49f4f48981362529d226e3}"
UNICODE_SELFTEST_PATCH="${HOST_WORKSPACE_DIR}/${UNICODE_SELFTEST_PATCH:-patches/unicode/unicode-12.1-default-ignorable-selftest.patch}"
UNICODE_SELFTEST_PATCH_SHA256="${UNICODE_SELFTEST_PATCH_SHA256:-ae0613638230c51ce95563783b307f1ca96efde0e73ada540c14f037438f8acd}"

apply_official_backport_once() {
    local label="$1" repo_mode="$2" repo_dir="$3" commit="$4" expected_patch_id="$5"
    local patch_file patch_id
    local git_cmd
    case "${repo_mode}" in
        worktree) git_cmd=(git -C "${repo_dir}") ;;
        bare) git_cmd=(git --git-dir="${repo_dir}") ;;
        *) die "${label}审计仓库模式无效" ;;
    esac
    patch_file="$(mktemp)"
    env GIT_NO_LAZY_FETCH=1 "${git_cmd[@]}" \
        cat-file -e "${commit}^{commit}" 2>/dev/null || \
        die "${label}对象缺失，请先运行 ./init.sh"
    env GIT_NO_LAZY_FETCH=1 "${git_cmd[@]}" -c log.mailmap=false \
        show --format= "${commit}" > "${patch_file}"
    patch_id="$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')"
    [ "${patch_id}" = "${expected_patch_id}" ] || die "${label} patch-id 不匹配"
    if git -C "${COMMON_DIR}" apply --check "${patch_file}" >/dev/null 2>&1; then
        log_step "应用 ${label}"
        git -C "${COMMON_DIR}" apply "${patch_file}"
    elif git -C "${COMMON_DIR}" apply --reverse --check "${patch_file}" >/dev/null 2>&1; then
        log_info "${label}已存在"
    else
        die "${label}无法干净应用或识别"
    fi
    git -C "${COMMON_DIR}" apply --reverse --check "${patch_file}" || \
        die "${label}状态不完整"
    rm -f "${patch_file}"
}

apply_aosp_backport_once() {
    apply_official_backport_once "$1" worktree "${AOSP_BACKPORT_AUDIT_DIR}" "$2" "$3"
}

apply_linux_stable_backport_once() {
    apply_official_backport_once "$1" bare "${LINUX_STABLE_AUDIT_DIR}" "$2" "$3"
}

verify_linux_stable_source() {
    local label="$1" commit="$2" expected_patch_id="$3"
    local patch_file patch_id
    patch_file="$(mktemp)"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        cat-file -e "${commit}^{commit}" 2>/dev/null || \
        die "${label}对象缺失，请先运行 ./init.sh"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        -c log.mailmap=false show --format= "${commit}" > "${patch_file}"
    patch_id="$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')"
    rm -f "${patch_file}"
    [ "${patch_id}" = "${expected_patch_id}" ] || die "${label} patch-id 不匹配"
}

verify_aosp_source() {
    local label="$1" commit="$2" expected_patch_id="$3"
    local patch_file patch_id
    patch_file="$(mktemp)"
    env GIT_NO_LAZY_FETCH=1 git -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        cat-file -e "${commit}^{commit}" 2>/dev/null || \
        die "${label}对象缺失，请先运行 ./init.sh"
    env GIT_NO_LAZY_FETCH=1 git -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        -c log.mailmap=false show --format= "${commit}" > "${patch_file}"
    patch_id="$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')"
    rm -f "${patch_file}"
    [ "${patch_id}" = "${expected_patch_id}" ] || die "${label} patch-id 不匹配"
}

apply_project_patch_once() {
    local label="$1" patch_file="$2" expected_sha256="$3" expected_patch_id="$4"
    local actual_sha256 patch_id
    [ -f "${patch_file}" ] || die "${label}补丁缺失"
    actual_sha256="$(sha256sum "${patch_file}" | awk '{ print $1 }')"
    [ "${actual_sha256}" = "${expected_sha256}" ] || die "${label} SHA-256 不匹配"
    patch_id="$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')"
    [ "${patch_id}" = "${expected_patch_id}" ] || die "${label} patch-id 不匹配"
    if git -C "${COMMON_DIR}" apply --check "${patch_file}" >/dev/null 2>&1; then
        log_step "应用 ${label}"
        git -C "${COMMON_DIR}" apply "${patch_file}"
    elif git -C "${COMMON_DIR}" apply --reverse --check "${patch_file}" >/dev/null 2>&1; then
        log_info "${label}已存在"
    else
        die "${label}无法干净应用或识别"
    fi
    git -C "${COMMON_DIR}" apply --reverse --check "${patch_file}" || \
        die "${label}状态不完整"
}

if [ "${ENABLE_TIMER_BASE_FAST_PATH}" = "1" ]; then
    apply_aosp_backport_once "AOSP timer base 指针获取快路径优化" \
        "${TIMER_BASE_FAST_PATH_COMMIT}" \
        "${TIMER_BASE_FAST_PATH_PATCH_ID}"
    grep -Fq 'return per_cpu_ptr(&timer_bases[index], cpu);' \
        "${COMMON_DIR}/kernel/time/timer.c" || \
        die "timer CPU base 快路径未使用单次 per_cpu_ptr"
    grep -Fq 'return this_cpu_ptr(&timer_bases[index]);' \
        "${COMMON_DIR}/kernel/time/timer.c" || \
        die "timer this CPU base 快路径未使用单次 this_cpu_ptr"
    log_success "AOSP timer base 指针获取快路径优化状态正确"
fi

if [ "${ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH}" = "1" ]; then
    apply_aosp_backport_once "AOSP F2FS DIO overwrite 映射检查优化" \
        "${F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT}" \
        "${F2FS_DIO_OVERWRITE_FAST_PATH_PATCH_ID}"
    grep -Fq 'static bool __f2fs_overwrite_io(struct inode *inode, loff_t pos, size_t len,' \
        "${COMMON_DIR}/fs/f2fs/data.c" || \
        die "F2FS DIO overwrite 优化缺少内部 helper"
    grep -Fq '!__f2fs_overwrite_io(inode, offset, length, true)' \
        "${COMMON_DIR}/fs/f2fs/data.c" || \
        die "F2FS iomap 未启用首映射检查"
    grep -Fq 'return __f2fs_overwrite_io(inode, pos, len, false);' \
        "${COMMON_DIR}/fs/f2fs/data.c" || \
        die "F2FS 原有完整 overwrite 检查语义被破坏"
    log_success "AOSP F2FS DIO overwrite 映射检查优化状态正确"
fi

if [ "${ENABLE_EAS_CPUMASK_FAST_PATH}" = "1" ]; then
    apply_aosp_backport_once "AOSP EAS cpumask 空集判断优化" \
        "${EAS_CPUMASK_FAST_PATH_COMMIT}" \
        "${EAS_CPUMASK_FAST_PATH_PATCH_ID}"
    grep -Fq 'if (!cpumask_and(cpus, perf_domain_span(pd), cpu_online_mask))' \
        "${COMMON_DIR}/kernel/sched/fair.c" || \
        die "EAS 未复用 cpumask_and 返回值"
    log_success "AOSP EAS cpumask 空集判断优化状态正确"
fi

if [ "${ENABLE_BLK_WBT_DONE_FAST_PATH}" = "1" ]; then
    apply_aosp_backport_once "AOSP blk-wbt 非节流写完成快路径优化" \
        "${BLK_WBT_DONE_FAST_PATH_COMMIT}" \
        "${BLK_WBT_DONE_FAST_PATH_PATCH_ID}"
    wbt_done_function="$(sed -n '/^static void wbt_done(/,/^}/p' \
        "${COMMON_DIR}/block/blk-wbt.c")"
    printf '%s\n' "${wbt_done_function}" | \
        grep -Fq 'if (wbt_is_read(rq)) {' || \
        die "blk-wbt 未将 read-only 状态更新置于读请求分支"
    log_success "AOSP blk-wbt 非节流写完成快路径优化状态正确"
fi

if [ "${ENABLE_F2FS_OPEN_FAST_PATH}" = "1" ]; then
    apply_aosp_backport_once "AOSP F2FS open 快路径优化" \
        "${F2FS_OPEN_FAST_PATH_COMMIT}" \
        "${F2FS_OPEN_FAST_PATH_PATCH_ID}"
    grep -Fq 'opened = is_inode_flag_set(inode, FI_OPENED_FILE);' \
        "${COMMON_DIR}/fs/f2fs/file.c" || \
        die "F2FS open 快路径未在 i_sem 保护下检查 FI_OPENED_FILE"
    log_success "AOSP F2FS open 快路径优化状态正确"
fi

if [ "${ENABLE_MEMCG_RSTAT_FAST_PATH}" = "1" ]; then
    apply_aosp_backport_once "Linux memcg rstat 快路径优化" \
        "${MEMCG_RSTAT_FAST_PATH_COMMIT}" \
        "${MEMCG_RSTAT_FAST_PATH_PATCH_ID}"
    grep -Fq 'if (memcg_vmstats_needs_flush(statc->vmstats))' \
        "${COMMON_DIR}/mm/memcontrol.c" || \
        die "memcg rstat 快路径未在祖先遍历前检查刷新状态"
    log_success "Linux memcg rstat 快路径优化状态正确"
fi

if [ "${ENABLE_TCP_RECV_MSTAMP_FAST_PATH}" = "1" ]; then
    apply_aosp_backport_once "Linux TCP recv 时间戳快路径优化" \
        "${TCP_RECV_MSTAMP_FAST_PATH_COMMIT}" \
        "${TCP_RECV_MSTAMP_FAST_PATH_PATCH_ID}"
    grep -Fq 'if (unlikely(!tp->rcv_rtt_est.rtt_us))' \
        "${COMMON_DIR}/net/ipv4/tcp_input.c" || \
        die "TCP recv 快路径未保留无 RTT 样本保护"
    log_success "Linux TCP recv 时间戳快路径优化状态正确"
fi

if [ "${ENABLE_F2FS_MERGE_PAGE_BIO_UAF_FIX}" = "1" ]; then
    patch_file="$(mktemp)"
    env GIT_NO_LAZY_FETCH=1 git -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        cat-file -e "${F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT}^{commit}" 2>/dev/null || \
        die "F2FS merge_page_bio UAF 修复对象缺失，请先运行 ./init.sh"
    env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        show --format= "${F2FS_MERGE_PAGE_BIO_UAF_FIX_COMMIT}" > "${patch_file}"
    [ "$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')" = \
      "${F2FS_MERGE_PAGE_BIO_UAF_FIX_PATCH_ID}" ] || \
        die "F2FS merge_page_bio UAF 修复 patch-id 不匹配"
    if git -C "${COMMON_DIR}" apply --check "${patch_file}" >/dev/null 2>&1; then
        log_step "应用 AOSP F2FS merge_page_bio 加密写回 UAF 修复"
        git -C "${COMMON_DIR}" apply "${patch_file}"
    elif git -C "${COMMON_DIR}" apply --reverse --check "${patch_file}" >/dev/null 2>&1; then
        log_info "AOSP F2FS merge_page_bio 加密写回 UAF 修复已存在"
    else
        die "AOSP F2FS merge_page_bio UAF 修复无法干净应用或识别"
    fi
    git -C "${COMMON_DIR}" apply --reverse --check "${patch_file}" || \
        die "AOSP F2FS merge_page_bio UAF 修复状态不完整"
    rm -f "${patch_file}"
    grep -Fq 'inc_page_count(fio->sbi, WB_DATA_TYPE(fio->page, false));' \
        "${COMMON_DIR}/fs/f2fs/data.c" || \
        die "F2FS merge_page_bio 仍可能统计已释放的加密 bounce page"
    log_success "AOSP F2FS merge_page_bio UAF 修复状态正确"
fi

if [ "${ENABLE_GUNYAH_CLEAN_RESOURCES_UAF_FIX}" = "1" ]; then
    apply_aosp_backport_once "AOSP Gunyah clean_resources UAF 修复" \
        "${GUNYAH_CLEAN_RESOURCES_UAF_FIX_COMMIT}" \
        "${GUNYAH_CLEAN_RESOURCES_UAF_FIX_PATCH_ID}"
    grep -Fq 'list_del(&ghrsc->list);' "${COMMON_DIR}/drivers/virt/gunyah/vm_mgr.c" || \
        die "Gunyah resource 释放前未从 VM 链表摘除"
    log_success "AOSP Gunyah clean_resources UAF 修复状态正确"
fi

if [ "${ENABLE_IDLETIMER_DESTROY_UAF_FIX}" = "1" ]; then
    apply_aosp_backport_once "AOSP IDLETIMER destroy UAF 修复" \
        "${IDLETIMER_DESTROY_UAF_FIX_COMMIT}" \
        "${IDLETIMER_DESTROY_UAF_FIX_PATCH_ID}"
    log_success "AOSP IDLETIMER destroy UAF 修复状态正确"
fi

if [ "${ENABLE_EVENTPOLL_RCU_UAF_FIX}" = "1" ]; then
    apply_aosp_backport_once "AOSP eventpoll RCU UAF 修复" \
        "${EVENTPOLL_RCU_UAF_FIX_COMMIT}" \
        "${EVENTPOLL_RCU_UAF_FIX_PATCH_ID}"
    grep -Fq 'kfree_rcu(ep, rcu);' "${COMMON_DIR}/fs/eventpoll.c" || \
        die "eventpoll 未延迟到 RCU grace period 后释放"
    log_success "AOSP eventpoll RCU UAF 修复状态正确"
fi

if [ "${ENABLE_CGROUP_KERNFS_UAF_FIX}" = "1" ]; then
    apply_aosp_backport_once "AOSP cgroup kernfs UAF 修复" \
        "${CGROUP_KERNFS_UAF_FIX_COMMIT}" \
        "${CGROUP_KERNFS_UAF_FIX_PATCH_ID}"
    log_success "AOSP cgroup kernfs UAF 修复状态正确"
fi

if [ "${ENABLE_F2FS_SYNC_INODE_META_UAF_FIX}" = "1" ]; then
    apply_aosp_backport_once "AOSP F2FS sync_inode_meta UAF 修复" \
        "${F2FS_SYNC_INODE_META_UAF_FIX_COMMIT}" \
        "${F2FS_SYNC_INODE_META_UAF_FIX_PATCH_ID}"
    log_success "AOSP F2FS sync_inode_meta UAF 修复状态正确"
fi

if [ "${ENABLE_TIMER_SHUTDOWN_SYNC_RACE_FIX}" = "1" ]; then
    apply_aosp_backport_once "AOSP timer shutdown_sync 竞态修复" \
        "${TIMER_SHUTDOWN_SYNC_RACE_FIX_COMMIT}" \
        "${TIMER_SHUTDOWN_SYNC_RACE_FIX_PATCH_ID}"
    log_success "AOSP timer shutdown_sync 竞态修复状态正确"
fi

if [ "${ENABLE_FUTEX_REQUEUE_PI_UAF_FIX}" = "1" ]; then
    apply_aosp_backport_once "AOSP futex requeue-PI UAF 修复" \
        "${FUTEX_REQUEUE_PI_UAF_FIX_COMMIT}" \
        "${FUTEX_REQUEUE_PI_UAF_FIX_PATCH_ID}"
    log_success "AOSP futex requeue-PI UAF 修复状态正确"
fi

if [ "${ENABLE_PAGE_POOL_DESTROY_RACE_FIX}" = "1" ]; then
    apply_aosp_backport_once "AOSP page_pool 销毁竞态修复" \
        "${PAGE_POOL_DESTROY_RACE_FIX_COMMIT}" \
        "${PAGE_POOL_DESTROY_RACE_FIX_PATCH_ID}"
    log_success "AOSP page_pool 销毁竞态修复状态正确"
fi

if [ "${ENABLE_CONNTRACK_UNCONFIRMED_RACE_FIX}" = "1" ]; then
    apply_aosp_backport_once "AOSP conntrack 未确认项并发删除修复" \
        "${CONNTRACK_UNCONFIRMED_RACE_FIX_COMMIT}" \
        "${CONNTRACK_UNCONFIRMED_RACE_FIX_PATCH_ID}"
    log_success "AOSP conntrack 未确认项并发删除修复状态正确"
fi

if [ "${ENABLE_EROFS_DIR_TAIL_OOB_FIX}" = "1" ]; then
    apply_aosp_backport_once "AOSP EROFS 目录尾项越界读取修复" \
        "${EROFS_DIR_TAIL_OOB_FIX_COMMIT}" \
        "${EROFS_DIR_TAIL_OOB_FIX_PATCH_ID}"
    log_success "AOSP EROFS 目录尾项越界读取修复状态正确"
fi

if [ "${ENABLE_EXT4_XATTR_OOB_FIX}" = "1" ]; then
    apply_aosp_backport_once "AOSP ext4 扩展属性边界越界读取修复" \
        "${EXT4_XATTR_OOB_FIX_COMMIT}" \
        "${EXT4_XATTR_OOB_FIX_PATCH_ID}"
    log_success "AOSP ext4 扩展属性边界越界读取修复状态正确"
fi

if [ "${ENABLE_IPV6_MLD_UAF_FIX}" = "1" ]; then
    apply_aosp_backport_once "AOSP IPv6 MLD 查询释放后访问修复" \
        "${IPV6_MLD_UAF_FIX_COMMIT}" \
        "${IPV6_MLD_UAF_FIX_PATCH_ID}"
    grep -Fq 'group = mld->mld_mca;' "${COMMON_DIR}/net/ipv6/mcast.c" || \
        die "IPv6 MLD 查询仍可能在 skb 重分配后使用旧 group 指针"
    log_success "AOSP IPv6 MLD 查询释放后访问修复状态正确"
fi

if [ "${ENABLE_STAGE5_RTMUTEX_FIX}" = "1" ]; then
    rtmutex_stack_patch_id="$(
        git -C "${COMMON_DIR}" diff HEAD -- \
            kernel/locking/rtmutex.c kernel/locking/rtmutex_api.c |
            git patch-id --stable | awk '{ print $1 }'
    )"
    patch_file="$(mktemp)"
    git -C "${COMMON_DIR}" cat-file -e "${STAGE5_RTMUTEX_FIX_COMMIT}^{commit}" 2>/dev/null || \
        die "阶段 5 AOSP rtmutex 修复对象缺失，请先运行 ./init.sh"
    git -C "${COMMON_DIR}" show --format= "${STAGE5_RTMUTEX_FIX_COMMIT}" > "${patch_file}"
    [ "$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')" = "${STAGE5_RTMUTEX_FIX_PATCH_ID}" ] || \
        die "阶段 5 AOSP rtmutex 修复 patch-id 不匹配"
    if git -C "${COMMON_DIR}" apply --check "${patch_file}" >/dev/null 2>&1; then
        log_step "应用 AOSP rtmutex waiter::task 安全修复"
        git -C "${COMMON_DIR}" apply "${patch_file}"
    elif git -C "${COMMON_DIR}" apply --reverse --check "${patch_file}" >/dev/null 2>&1; then
        log_info "AOSP rtmutex waiter::task 安全修复已存在"
    elif [ "${ENABLE_RTMUTEX_WAITER_ENQUEUE_FIX}" = "1" ] &&
         [ "${rtmutex_stack_patch_id}" = "${RTMUTEX_FIX_STACK_PATCH_ID}" ]; then
        log_info "AOSP rtmutex waiter::task 安全修复已包含在固定修复栈"
    else
        die "AOSP rtmutex waiter::task 安全修复无法干净应用或识别"
    fi
    rm -f "${patch_file}"
    log_success "阶段 5 AOSP rtmutex 安全修复状态正确"
else
    log_info "当前阶段没有项目自有的内核直接调优补丁"
fi

if [ "${ENABLE_RTMUTEX_WAITER_ENQUEUE_FIX}" = "1" ]; then
    apply_aosp_backport_once "AOSP rtmutex 未入队 waiter 错误路径修复" \
        "${RTMUTEX_WAITER_ENQUEUE_FIX_COMMIT}" \
        "${RTMUTEX_WAITER_ENQUEUE_FIX_PATCH_ID}"
    grep -Fq 'if (!waiter_task) /* never enqueued */' \
        "${COMMON_DIR}/kernel/locking/rtmutex.c" || \
        die "rtmutex remove_waiter 仍可能解引用未入队 waiter"
    grep -Fq 'if (unlikely(ret < 0))' \
        "${COMMON_DIR}/kernel/locking/rtmutex_api.c" || \
        die "rtmutex proxy lock 成功路径仍错误调用 remove_waiter"
    [ "$(
        git -C "${COMMON_DIR}" diff HEAD -- \
            kernel/locking/rtmutex.c kernel/locking/rtmutex_api.c |
            git patch-id --stable | awk '{ print $1 }'
      )" = "${RTMUTEX_FIX_STACK_PATCH_ID}" ] || \
        die "rtmutex 固定修复栈 patch-id 不匹配"
    log_success "AOSP rtmutex 未入队 waiter 错误路径修复状态正确"
fi

if [ "${ENABLE_FUTEX_EXITING_POINTER_FIX}" = "1" ]; then
    apply_linux_stable_backport_once "Linux futex PI stale exiting 指针修复" \
        "${FUTEX_EXITING_POINTER_STABLE_COMMIT}" \
        "${FUTEX_EXITING_POINTER_PATCH_ID}"
    grep -A2 -F 'retry:' "${COMMON_DIR}/kernel/futex/pi.c" |
        grep -Fq 'exiting = NULL;' || \
        die "futex_lock_pi retry 未清除 exiting 指针"
    log_success "Linux futex PI stale exiting 指针修复状态正确"
fi

if [ "${ENABLE_FUTEX_REQUEUE_PI_LOCKUP_FIX}" = "1" ]; then
    apply_linux_stable_backport_once "Linux futex requeue-PI 超时竞态活锁修复" \
        "${FUTEX_REQUEUE_PI_LOCKUP_STABLE_COMMIT}" \
        "${FUTEX_REQUEUE_PI_LOCKUP_PATCH_ID}"
    grep -A5 -F 'if (!futex_requeue_pi_prepare(top_waiter, NULL)) {' \
        "${COMMON_DIR}/kernel/futex/requeue.c" |
        grep -Fq 'plist_del(&top_waiter->list, &hb1->chain);' || \
        die "futex requeue-PI 失败路径未摘除顶层 waiter"
    grep -Fq 'if (!plist_node_empty(&q->list)) {' \
        "${COMMON_DIR}/kernel/futex/requeue.c" || \
        die "futex early requeue-PI wakeup 仍无条件重复摘链"
    log_success "Linux futex requeue-PI 超时竞态活锁修复状态正确"
fi

if [ "${ENABLE_F2FS_ACL_ENTRY_BOUNDS_FIX}" = "1" ]; then
    apply_linux_stable_backport_once "Linux F2FS ACL 条目边界修复" \
        "${F2FS_ACL_ENTRY_BOUNDS_STABLE_COMMIT}" \
        "${F2FS_ACL_ENTRY_BOUNDS_PATCH_ID}"
    grep -Fq 'sizeof(struct f2fs_acl_entry_short) > end' \
        "${COMMON_DIR}/fs/f2fs/acl.c" || \
        die "F2FS ACL 短条目读取前未验证边界"
    grep -Fq 'err = -EFSCORRUPTED;' "${COMMON_DIR}/fs/f2fs/acl.c" || \
        die "F2FS ACL 损坏条目未返回 EFSCORRUPTED"
    log_success "Linux F2FS ACL 条目边界修复状态正确"
fi

if [ "${ENABLE_F2FS_LISTXATTR_BOUNDS_FIX}" = "1" ]; then
    apply_linux_stable_backport_once "Linux F2FS listxattr 条目边界修复" \
        "${F2FS_LISTXATTR_BOUNDS_STABLE_COMMIT}" \
        "${F2FS_LISTXATTR_BOUNDS_PATCH_ID}"
    grep -A9 -F 'sizeof(__u32) > last_base_addr' \
        "${COMMON_DIR}/fs/f2fs/xattr.c" |
        grep -Fq 'error = -EFSCORRUPTED;' || \
        die "F2FS listxattr 损坏条目仍返回部分成功结果"
    log_success "Linux F2FS listxattr 条目边界修复状态正确"
fi

if [ "${ENABLE_BLKCG_RSTAT_RELEASE_FIX}" = "1" ]; then
    apply_linux_stable_backport_once "Linux blk-cgroup rstat 释放竞态修复" \
        "${BLKCG_RSTAT_RELEASE_STABLE_COMMIT}" \
        "${BLKCG_RSTAT_RELEASE_PATCH_ID}"
    grep -A15 -F 'static void blkg_release(struct percpu_ref *ref)' \
        "${COMMON_DIR}/block/blk-cgroup.c" |
        grep -Fq '__blkcg_rstat_flush(blkcg, cpu);' || \
        die "blk-cgroup rstat 未在 call_rcu 前刷新"
    log_success "Linux blk-cgroup rstat 释放竞态修复状态正确"
fi

if [ "${ENABLE_BINDER_TRANSACTION_LIFETIME_FIX}" = "1" ]; then
    verify_linux_stable_source "Linux Binder thread release 生命周期修复" \
        "${BINDER_THREAD_RELEASE_STABLE_COMMIT}" \
        "${BINDER_THREAD_RELEASE_PATCH_ID}"
    verify_linux_stable_source "Linux Binder transaction free 生命周期修复" \
        "${BINDER_FREE_TRANSACTION_STABLE_COMMIT}" \
        "${BINDER_FREE_TRANSACTION_PATCH_ID}"
    apply_project_patch_once "Linux Binder transaction 生命周期修复（Android vendor hook 适配）" \
        "${BINDER_TRANSACTION_LIFETIME_PATCH}" \
        "${BINDER_TRANSACTION_LIFETIME_PATCH_SHA256}" \
        "${BINDER_TRANSACTION_LIFETIME_PATCH_ID}"
    binder_free_function="$(sed -n \
        '/^static void binder_free_transaction(/,/^}/p' \
        "${COMMON_DIR}/drivers/android/binder.c")"
    printf '%s\n' "${binder_free_function}" | \
        grep -Fq 'spin_lock(&t->lock);' || \
        die "Binder transaction 未在锁内读取目标"
    printf '%s\n' "${binder_free_function}" | \
        grep -Fq 'atomic_inc(&target_thread->tmp_ref);' || \
        die "Binder transaction 未固定目标线程生命周期"
    printf '%s\n' "${binder_free_function}" | \
        grep -Fq 'binder_thread_dec_tmpref(target_thread);' || \
        die "Binder transaction 未释放目标线程临时引用"
    printf '%s\n' "${binder_free_function}" | \
        grep -Fq 'trace_android_vh_free_oem_binder_struct(t);' || \
        die "Binder transaction 修复破坏 Android vendor hook"
    log_success "Linux Binder transaction 生命周期修复状态正确"
fi

f2fs_gc_deadlock_fix_complete() {
    grep -Fq 'void f2fs_submit_all_merged_ipu_writes(struct f2fs_sb_info *sbi)' \
        "${COMMON_DIR}/fs/f2fs/data.c" &&
    awk '
        /^void f2fs_balance_fs\(/ { body = 1 }
        body && /f2fs_submit_all_merged_ipu_writes\(sbi\);/ { flushed = NR }
        body && /test_opt\(sbi, GC_MERGE\)/ {
            if (!flushed || flushed >= NR)
                exit 1
            checked = 1
        }
        body && /^}/ { exit !checked }
        END { if (!checked) exit 1 }
    ' "${COMMON_DIR}/fs/f2fs/segment.c"
}

if [ "${ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX}" = "1" ]; then
    verify_linux_stable_source "Linux F2FS 前台 GC 写回死锁修复" \
        "${F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT}" \
        "${F2FS_FOREGROUND_GC_DEADLOCK_PATCH_ID}"
    verify_linux_stable_source "Linux F2FS GC_MERGE 写回死锁补充修复" \
        "${F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT}" \
        "${F2FS_GC_MERGE_DEADLOCK_PATCH_ID}"
    if f2fs_gc_deadlock_fix_complete; then
        log_info "Linux F2FS 前台 GC 写回死锁修复组合已存在"
    else
        apply_linux_stable_backport_once "Linux F2FS 前台 GC 写回死锁修复" \
            "${F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT}" \
            "${F2FS_FOREGROUND_GC_DEADLOCK_PATCH_ID}"
        apply_linux_stable_backport_once "Linux F2FS GC_MERGE 写回死锁补充修复" \
            "${F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT}" \
            "${F2FS_GC_MERGE_DEADLOCK_PATCH_ID}"
    fi
    f2fs_gc_deadlock_fix_complete || \
        die "F2FS 缓存 bio 未在 GC_MERGE 分支前统一提交"
    log_success "Linux F2FS 前台 GC 写回死锁修复状态正确"
fi

if [ "${ENABLE_F2FS_ATOMIC_INODE_UAF_FIX}" = "1" ]; then
    apply_linux_stable_backport_once "Linux F2FS atomic inode 生命周期修复" \
        "${F2FS_ATOMIC_INODE_UAF_STABLE_COMMIT}" \
        "${F2FS_ATOMIC_INODE_UAF_PATCH_ID}"
    [ "$(grep -Fc 'atomic_inode = igrab(F2FS_I(inode)->atomic_inode);' \
        "${COMMON_DIR}/fs/f2fs/gc.c")" = "2" ] || \
        die "F2FS atomic inode 未在两个 GC 路径固定引用"
    grep -Fq 'f2fs_down_write(&F2FS_I(cow_inode)->i_sem);' \
        "${COMMON_DIR}/fs/f2fs/inode.c" || \
        die "F2FS cow inode 解绑未持有 i_sem"
    log_success "Linux F2FS atomic inode 生命周期修复状态正确"
fi

if [ "${ENABLE_UFS_RUNTIME_PM_ERROR_RECOVERY_FIX}" = "1" ]; then
    verify_aosp_source "AOSP UFS runtime suspend 错误恢复死锁修复" \
        "${UFS_RUNTIME_SUSPEND_DEADLOCK_AOSP_COMMIT}" \
        "${UFS_RUNTIME_SUSPEND_DEADLOCK_PATCH_ID}"
    verify_aosp_source "AOSP UFS error handler host_sem 补充修复" \
        "${UFS_ERROR_HANDLER_HOST_SEM_AOSP_COMMIT}" \
        "${UFS_ERROR_HANDLER_HOST_SEM_PATCH_ID}"
    verify_aosp_source "AOSP UFS error handler WLUN 空指针补充修复" \
        "${UFS_ERROR_HANDLER_WLUN_AOSP_COMMIT}" \
        "${UFS_ERROR_HANDLER_WLUN_PATCH_ID}"
    apply_project_patch_once "AOSP UFS runtime PM 错误恢复组合修复（r57 语义适配）" \
        "${UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH}" \
        "${UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH_SHA256}" \
        "${UFS_RUNTIME_PM_ERROR_RECOVERY_PATCH_ID}"
    ufs_error_handler="$(sed -n '/^static void ufshcd_err_handler(/,/^}/p' \
        "${COMMON_DIR}/drivers/ufs/core/ufshcd.c")"
    printf '%s\n' "${ufs_error_handler}" | \
        grep -Fq 'if (hba->ufs_device_wlun) {' || \
        die "UFS error handler 未保护未初始化 WLUN"
    [ "$(printf '%s\n' "${ufs_error_handler}" | \
        grep -Fc 'ufshcd_rpm_put(hba);')" = "2" ] || \
        die "UFS error handler runtime PM 引用不平衡"
    printf '%s\n' "${ufs_error_handler}" | awk '
        /ufshcd_rpm_get_noresume\(hba\);/ { rpm = NR }
        /down\(&hba->host_sem\);/ {
            if (!rpm || rpm >= NR)
                exit 1
            checked = 1
            exit 0
        }
        END { if (!checked) exit 1 }
    ' || die "UFS runtime PM 检查未置于 host_sem 获取之前"
    log_success "AOSP UFS runtime PM 错误恢复组合修复状态正确"
fi

if [ "${ENABLE_UNICODE_IGNORABLE_FIX}" = "1" ]; then
    git -C "${COMMON_DIR}" cat-file -e "${UNICODE_FIX_COMMIT}^" 2>/dev/null || \
        die "AOSP Unicode 修复或父对象缺失，请先运行 ./init.sh"
    [ -s "${UNICODE_FIX_PATCH}" ] || die "缺少 Unicode 6.12.23 兼容补丁"
    [ "$(sha256sum "${UNICODE_FIX_PATCH}" | awk '{ print $1 }')" = "${UNICODE_FIX_PATCH_SHA256}" ] || \
        die "Unicode 兼容补丁 SHA-256 不匹配"
    if git -C "${COMMON_DIR}" apply --recount --check "${UNICODE_FIX_PATCH}" >/dev/null 2>&1; then
        log_step "应用 Unicode default-ignorable 修复与 ext4/f2fs 旧哈希兼容"
        git -C "${COMMON_DIR}" apply --recount "${UNICODE_FIX_PATCH}"
    elif git -C "${COMMON_DIR}" apply --recount --reverse --check "${UNICODE_FIX_PATCH}" >/dev/null 2>&1; then
        log_info "Unicode default-ignorable 兼容修复已存在"
    else
        die "Unicode 6.12.23 兼容修复无法干净应用或识别"
    fi
    ! grep -Fq 'ignore_init();' "${COMMON_DIR}/fs/unicode/mkutf8data.c" || \
        die "Unicode 生成器仍在特殊处理 default-ignorable 码点"
    git -C "${COMMON_DIR}" apply --recount --reverse --check "${UNICODE_FIX_PATCH}" || \
        die "Unicode 兼容修复状态不完整"
    grep -Fq 'f2fs_set_lookup_mode(sbi, LOOKUP_AUTO);' "${COMMON_DIR}/fs/f2fs/super.c" || \
        die "f2fs 默认 lookup_mode 未启用自动兼容回退"

    [ -s "${UNICODE_SELFTEST_PATCH}" ] || die "缺少 Unicode 12.1 全码点自测补丁"
    [ "$(sha256sum "${UNICODE_SELFTEST_PATCH}" | awk '{ print $1 }')" = "${UNICODE_SELFTEST_PATCH_SHA256}" ] || \
        die "Unicode 全码点自测补丁 SHA-256 不匹配"
    if git -C "${COMMON_DIR}" apply --recount --check "${UNICODE_SELFTEST_PATCH}" >/dev/null 2>&1; then
        log_step "加入 Unicode 12.1 全部 Default-Ignorable 码点回归测试"
        git -C "${COMMON_DIR}" apply --recount "${UNICODE_SELFTEST_PATCH}"
    elif git -C "${COMMON_DIR}" apply --recount --reverse --check "${UNICODE_SELFTEST_PATCH}" >/dev/null 2>&1; then
        log_info "Unicode 12.1 全码点回归测试已存在"
    else
        die "Unicode 12.1 全码点自测补丁无法干净应用或识别"
    fi
    git -C "${COMMON_DIR}" apply --recount --reverse --check "${UNICODE_SELFTEST_PATCH}" || \
        die "Unicode 12.1 全码点自测状态不完整"
    grep -Fq 'checked == 4173' "${COMMON_DIR}/fs/unicode/utf8-selftest.c" || \
        die "Unicode 12.1 Default-Ignorable 码点覆盖数异常"
    log_success "Unicode 修复、旧 casefold 目录兼容及全码点自测源码状态正确"
fi

log_success "内部 patch 阶段完成"
