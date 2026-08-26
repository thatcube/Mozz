using Mozz.V1;

namespace Mozz.Desktop.Core.Downloads;

/// <summary>
/// The one operation the typed download client needs from the core: send a
/// schema-described <see cref="Request"/> and get its <see cref="Response"/>.
///
/// It exists purely as a seam. <see cref="MozzCore"/> implements it against the
/// real Swift library; a test implements it in memory. Without it, the download
/// client could only be exercised with the dylib present, which is exactly the
/// coupling that let the whole download surface exist in the core while nothing
/// on this side could reach it.
/// </summary>
public interface ICoreInvoker
{
    Response Invoke(Request request);

    Task<Response> InvokeAsync(Request request, CancellationToken token = default);
}
