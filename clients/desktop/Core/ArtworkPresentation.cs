namespace Mozz.Desktop.Core;

public static class ArtworkPresentation
{
    public readonly record struct Crop(double X, double Y, double Width, double Height);

    public static bool ShouldUseCircularArtistPortrait(double width, double height)
    {
        if (width <= 0 || height <= 0) return false;
        var ratio = width / height;
        return ratio is >= 0.72 and <= 1.38;
    }

    public static Crop CoverCrop(double sourceWidth, double sourceHeight, double destinationWidth, double destinationHeight)
    {
        if (sourceWidth <= 0 || sourceHeight <= 0 || destinationWidth <= 0 || destinationHeight <= 0)
            return new Crop(0, 0, sourceWidth, sourceHeight);

        var sourceRatio = sourceWidth / sourceHeight;
        var destinationRatio = destinationWidth / destinationHeight;
        if (sourceRatio > destinationRatio)
        {
            var width = sourceHeight * destinationRatio;
            return new Crop((sourceWidth - width) / 2, 0, width, sourceHeight);
        }

        var height = sourceWidth / destinationRatio;
        return new Crop(0, (sourceHeight - height) / 2, sourceWidth, height);
    }
}
