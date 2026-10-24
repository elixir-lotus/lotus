# Run dialyzer with MIX_ENV=test, as CI does — `mix lint` and a bare
# `mix dialyzer` use :dev, where test/support/* is not compiled and its
# filters below are reported as "Unnecessary Skips". They are not stale.
[
  # OTP 27 infers a precise map shape for this test helper and flags the
  # intentionally-broad map() spec as a supertype; OTP 28 collapses it to
  # map() and stays silent. The map() return type is deliberate.
  {"test/support/in_memory_adapter.ex", :contract_supertype, 96}
]
