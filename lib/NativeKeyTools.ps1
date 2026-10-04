# Same-user native twenty-key rollback profile; no changes merely by importing.
. (Join-Path $PSScriptRoot 'PortableTools.ps1')
$script:NativeKeysHash = 'C7457983D5B09B8F1A4D4770F4386E5750077D1A29B4F285D1ABDFC83615C5CB'
$script:IndependentKeysHash = '52776E6B2D105DF4CD0FF7EC8933E8170F7A404D1D6FD68288CA5C44AF0CC0AD'
$script:NativeKeysDeltaHash = '22A0BADF624045720CF979D4BBC5FD6AA74B53509CA77430C997A676F5116AFC'
$script:PortablePreviousHash = $script:IndependentKeysHash
$script:PortableTargetHash = $script:NativeKeysHash
function Assert-NativeKeyScheme($Scheme) {
    if ($Scheme.count -ne 20) { throw 'Native key mode requires exactly twenty messages; no entries discarded.' }
    for ($i = 0; $i -lt 20; $i++) {
        $expected = '~+' + (($i + 1) % 10).ToString()
        if ($i -ge 10) { $expected = '~+F' + ($i - 9).ToString() }
        $binding = Get-HotkeyBinding ([string]$Scheme.('bind' + $i))
        if ($binding.Label -ne $expected) { throw ('Native key mode requires ' + $expected + ' at entry ' + ($i + 1) + '; source retained.') }
    }
}
