function Clear-BundleToolchainEnvironment {
    # Member access on an empty pipeline yields $null inside @(...). Expanding
    # names in the pipeline instead keeps the no-Swift case empty, so Env: itself
    # can never become a removal target.
    $names = @(Get-ChildItem Env: | Where-Object { $_.Name -like 'SWIFT*' } |
        Select-Object -ExpandProperty Name)
    foreach ($name in $names + @('SDKROOT', 'DEVELOPER_DIR', 'ICU_DATA')) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
}
