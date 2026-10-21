output "runtime_binding_contract" {
  description = "Applied Lambda identity facts consumed by the authenticated agent handoff; live provider verification remains required."
  value       = module.honua.runtime_binding_contract
}
