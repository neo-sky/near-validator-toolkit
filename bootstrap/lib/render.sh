# shellcheck shell=bash
# Whitelisted envsubst rendering. Eager envsubst destroys ${...} tokens inside
# Grafana template variables, Go templates in contact-point messages, and
# Prometheus relabel configs. Always pass the explicit variable list.

render_template() {
    local src="$1"
    local dst="$2"
    shift 2
    [[ -f "$src" ]] || die "template not found: $src"
    [[ $# -gt 0 ]] || die "render_template: no variables specified for $src"
    local placeholders=""
    local var
    for var in "$@"; do
        placeholders+="\${${var}} "
    done
    mkdir -p "$(dirname "$dst")"
    envsubst "$placeholders" < "$src" > "${dst}.new"
    mv "${dst}.new" "$dst"
}
