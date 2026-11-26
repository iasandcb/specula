namespace Specula;

/// <summary>A Korean, user-visible failure of the existing RFB or display-helper protocol.</summary>
public sealed class ProtocolException : IOException
{
    public ProtocolException(string message) : base(message) { }

    public ProtocolException(string message, Exception inner) : base(message, inner) { }
}

public sealed class PairingRequiredException : IOException
{
    public PairingRequiredException(string message = "맥의 연결 코드로 다시 연결해 주세요.") : base(message) { }
}
