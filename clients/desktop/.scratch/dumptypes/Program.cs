using System.Reflection;
var asm = Assembly.Load("Hexa.NET.MiniAudio");
Console.WriteLine("== enums/structs with 'Device' ==");
foreach (var t in asm.GetExportedTypes())
    if (t.Name.Contains("Device") || t.Name.Contains("Waveform") || t.Name.Contains("Format"))
        Console.WriteLine($"{(t.IsEnum?"enum":t.IsValueType?"struct":"class")} {t.FullName}");
Console.WriteLine("== static funcs (sample) ==");
var ma = asm.GetType("Hexa.NET.MiniAudio.MiniAudio");
if (ma!=null) {
  foreach (var m in ma.GetMethods(BindingFlags.Public|BindingFlags.Static))
    if (m.Name.Contains("Device")||m.Name.Contains("Waveform")||m.Name.StartsWith("MaDevice"))
       Console.WriteLine(m.Name);
} else Console.WriteLine("no MiniAudio class; listing namespaces:");
if (ma==null) foreach (var t in asm.GetExportedTypes().Take(40)) Console.WriteLine(t.FullName);
