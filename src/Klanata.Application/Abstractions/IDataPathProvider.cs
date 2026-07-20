namespace Klanata.Application.Abstractions;

public interface IDataPathProvider
{
    string DataRoot { get; }

    string DatabasePath { get; }

    string LogsPath { get; }

    string KeysPath { get; }

    string BackupsPath { get; }

    string RuntimePath { get; }
}
