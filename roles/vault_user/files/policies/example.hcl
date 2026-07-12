# Example Vault policy - copy this to a new file (e.g. policies/alice.hcl),
# edit the path(s) to match what that specific person actually needs, then
# pass it via -e target_policy_file=... when running
# playbooks/manage_user.yml. Real policies should be scoped as narrowly as
# the person's actual job - this is a starting point, not a template to
# apply unedited to everyone.
#
# This example: read-only access to a "myapp" KV v2 mount, nothing else.

path "secret/data/myapp/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/myapp/*" {
  capabilities = ["list"]
}
