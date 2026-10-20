using System;

internal static class SshAskpass
{
    private static int Main()
    {
        string password = Environment.GetEnvironmentVariable("SERVICE_OPS_SSH_PASSWORD");
        if (String.IsNullOrEmpty(password)) return 1;
        Console.Out.WriteLine(password);
        return 0;
    }
}
