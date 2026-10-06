project('singularity-accounts', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

add_project_arguments('-DGETTEXT_PACKAGE="singularity-accounts"', language: 'c')

glib_dep   = dependency('glib-2.0')
gio_dep    = dependency('gio-2.0')
json_dep   = dependency('json-glib-1.0')
soup_dep   = dependency('libsoup-3.0')
secret_dep = dependency('libsecret-1')
gee_dep    = dependency('gee-0.8')

fs = import('fs')
python3 = find_program('python3')
oauth_clients_file = get_option('oauth_clients_file')
if oauth_clients_file != '' and fs.is_file(oauth_clients_file)
  build_config_vala = configure_file(
    input: oauth_clients_file,
    output: 'build_config.vala',
    command: [python3, files('src/gen_build_config.py'), '@INPUT@', '@OUTPUT@'],
  )
else
  build_config_vala = configure_file(
    output: 'build_config.vala',
    command: [python3, files('src/gen_build_config.py'), '@OUTPUT@'],
  )
endif

core_sources = [build_config_vala] + files(
  'src/errors.vala',
  'src/records.vala',
  'src/oauth.vala',
  'src/redirect.vala',
  'src/probe.vala',
  'src/providers.vala',
)

executable('singularity-accounts',
  core_sources + files(
    'src/secrets.vala',
    'src/flows.vala',
    'src/media_providers.vala',
    'src/service.vala',
    'src/main.vala',
  ),
  dependencies: [glib_dep, gio_dep, json_dep, soup_dep, secret_dep, gee_dep],
  c_args: ['-DG_LOG_DOMAIN="singularity-accounts"'],
  install: true,
  install_dir: get_option('libexecdir'),
)

webkit_dep = dependency('webkitgtk-6.0', required: false)
gtk_dep = dependency('gtk4', required: false)
if webkit_dep.found() and gtk_dep.found()
  libsingularity_dep = dependency('singularity-1.0', fallback: ['libsingularity', 'libsingularity_dep'])
  executable('singularity-accounts-signin',
    files('src/errors.vala', 'src/redirect.vala', 'signin/signin.vala'),
    dependencies: [glib_dep, gio_dep, gtk_dep, webkit_dep, gee_dep, libsingularity_dep],
    vala_args: ['--vapidir=' + meson.global_build_root() / 'subprojects' / 'libsingularity'],
    c_args: ['-DG_LOG_DOMAIN="singularity-accounts-signin"'],
    install: true,
    install_dir: get_option('libexecdir'),
  )
  install_data('data/dev.sinty.AccountsSignIn.desktop', install_dir: get_option('datadir') / 'applications')
endif

fuse_dep = dependency('fuse3', version: '>= 3.10', required: false)
mount_gtk_dep = dependency('gtk4', required: false)
if fuse_dep.found() and mount_gtk_dep.found()
  mount_lib_dep = dependency('singularity-1.0', fallback: ['libsingularity', 'libsingularity_dep'])
  posix_dep = meson.get_compiler('vala').find_library('posix')
  mount_vala_args = ['--vapidir=' + meson.current_source_dir() / 'mount', '--pkg=cloudfs',
    '--vapidir=' + meson.global_build_root() / 'subprojects' / 'libsingularity']
  mount_core = files('mount/names.vala', 'mount/nodes.vala', 'mount/cache.vala')
  cloudfs_lib = static_library('cloudfs', 'mount/cloudfs.c',
    dependencies: [glib_dep, gio_dep, fuse_dep],
  )
  executable('singularity-cloud-mount',
    mount_core + files('mount/drive_fs.vala', 'mount/service.vala', 'mount/main.vala'),
    dependencies: [glib_dep, gio_dep, json_dep, soup_dep, gee_dep, posix_dep, mount_lib_dep],
    link_with: cloudfs_lib,
    vala_args: mount_vala_args,
    include_directories: include_directories('mount'),
    c_args: ['-DG_LOG_DOMAIN="singularity-cloud-mount"'],
    install: true,
    install_dir: get_option('libexecdir'),
  )
  mount_conf = configuration_data()
  mount_conf.set('libexecdir', get_option('prefix') / get_option('libexecdir'))
  configure_file(
    input: 'data/dev.sinty.CloudMount.service.in',
    output: 'dev.sinty.CloudMount.service',
    configuration: mount_conf,
    install: true,
    install_dir: get_option('datadir') / 'dbus-1' / 'services',
  )
  configure_file(
    input: 'data/dev.sinty.CloudMount.desktop.in',
    output: 'dev.sinty.CloudMount.desktop',
    configuration: mount_conf,
    install: true,
    install_dir: get_option('sysconfdir') / 'xdg' / 'autostart',
  )
  cloud_mount_test = executable('cloud-mount-test',
    mount_core + files('tests/mount_test.vala'),
    dependencies: [glib_dep, gio_dep, json_dep, soup_dep, gee_dep, posix_dep, mount_lib_dep],
    vala_args: mount_vala_args,
  )
  test('cloud-mount', cloud_mount_test)
endif

service_conf = configuration_data()
service_conf.set('libexecdir', get_option('prefix') / get_option('libexecdir'))
configure_file(
  input: 'data/dev.sinty.Accounts.service.in',
  output: 'dev.sinty.Accounts.service',
  configuration: service_conf,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services',
)

accounts_daemon_test = executable('accounts-daemon-test',
  core_sources + files('src/flows.vala', 'src/media_providers.vala', 'src/secrets.vala', 'src/service.vala', 'tests/daemon_test.vala'),
  dependencies: [glib_dep, gio_dep, json_dep, soup_dep, secret_dep, gee_dep],
)
test('accounts-daemon', accounts_daemon_test, env: ['TMPDIR=' + meson.current_build_dir(), 'GIO_USE_PROXY_RESOLVER=dummy',
  'XDG_CONFIG_HOME=' + meson.current_build_dir() / 'test-config',
  'XDG_DATA_DIRS=' + meson.current_build_dir() / 'test-data',
  'ACCOUNTS_TEST_DATA=' + meson.current_build_dir() / 'test-data'])

install_data(files(
    'data/icons/singularity-account-media-server.svg',
    'data/icons/singularity-account-media-server-symbolic.svg',
    'data/icons/singularity-account-listening.svg',
    'data/icons/singularity-account-listening-symbolic.svg',
    'data/icons/singularity-account-music-service.svg',
    'data/icons/singularity-account-music-service-symbolic.svg',
  ),
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps')
