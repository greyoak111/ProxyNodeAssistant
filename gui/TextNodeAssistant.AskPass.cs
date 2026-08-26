using System;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;

namespace TextNodeAssistant.AskPass
{
    internal static class Program
    {
        private const int StdOutputHandle = -11;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int standardHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool WriteFile(IntPtr handle, byte[] buffer, int bytesToWrite, out int bytesWritten, IntPtr overlapped);

        [STAThread]
        private static int Main(string[] args)
        {
            string pipeName = Environment.GetEnvironmentVariable("TNA_ASKPASS_PIPE");
            if (String.IsNullOrWhiteSpace(pipeName)) pipeName = Environment.GetEnvironmentVariable("PNA_ASKPASS_PIPE");
            if (String.IsNullOrWhiteSpace(pipeName)) return 1;
            string prompt = args == null || args.Length == 0 ? "OpenSSH password" : String.Join(" ", args);
            try
            {
                string password;
                using (NamedPipeClientStream pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.None))
                {
                    pipe.Connect(30000);
                    using (BinaryWriter writer = new BinaryWriter(pipe, new UTF8Encoding(false), true))
                    using (BinaryReader reader = new BinaryReader(pipe, new UTF8Encoding(false), true))
                    {
                        writer.Write(prompt);
                        writer.Flush();
                        password = reader.ReadString();
                    }
                }
                if (String.IsNullOrEmpty(password)) return 1;
                byte[] payload = Encoding.UTF8.GetBytes(password + "\n");
                password = null;
                int written;
                return WriteFile(GetStdHandle(StdOutputHandle), payload, payload.Length, out written, IntPtr.Zero) && written == payload.Length ? 0 : 1;
            }
            catch
            {
                return 1;
            }
        }
    }
}
