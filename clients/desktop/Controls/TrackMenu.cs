using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Input;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.VisualTree;
// Avalonia has a `Track` of its own — the slider part — and this file is about
// the other kind.
using Mozz.Desktop.ViewModels;
using Track = Mozz.Desktop.Core.Track;

namespace Mozz.Desktop.Controls;

/// <summary>
/// The commands a track's context menu invokes.
/// </summary>
/// <remarks>
/// An interface rather than a direct reference to the view model, so this
/// control does not reach up into the layer that hosts it. The view model
/// already exposes every one of these as a generated command; declaring the
/// interface on it adds nothing but the name.
/// </remarks>
/// <summary>One track and the rating being given to it.</summary>
/// <remarks>
/// A command takes one parameter and rating needs two, so the pair travels as
/// one value rather than the menu holding the track in a field that a recycled
/// row would invalidate.
/// </remarks>
public sealed record TrackRating(Track Track, double? Stars);

public interface ITrackMenuCommands
{
    /// <summary>
    /// Whether this server keeps star ratings rather than a boolean favourite.
    ///
    /// Plex has per-user ratings and no favourite; Jellyfin is the reverse.
    /// Offering "Like" on Plex throws away four fifths of what the server can
    /// record, and offering stars on Jellyfin promises precision it cannot
    /// keep.
    /// </summary>
    bool UsesRatings { get; }

    ICommand RateTrackCommand { get; }
    ICommand ToggleFavoriteCommand { get; }
    ICommand PlayTrackNextCommand { get; }
    ICommand AddTrackToQueueCommand { get; }
    ICommand StartTrackRadioCommand { get; }
    ICommand OpenTrackArtistCommand { get; }
    ICommand OpenTrackAlbumCommand { get; }
    ICommand DownloadTrackCommand { get; }
    ICommand SuppressTrackCommand { get; }
    ICommand SuppressTrackArtistCommand { get; }
}

/// <summary>
/// Puts the track context menu on any row that names its track.
/// </summary>
/// <remarks>
/// The menu was written inline in one template and so existed on exactly one
/// list. Right-clicking a song on an album page, in a playlist, in the search
/// section or on Home did nothing at all, while the same right-click in Songs
/// offered seven actions — and the phones offer them on every row.
///
/// Attached rather than shared as a resource because a `MenuFlyout` belongs to
/// one control: attaching a single instance to six templates is not something
/// Avalonia supports, and repeating thirty lines of XAML six times is how the
/// menus drift apart. Each row gets its own flyout, built once here.
///
/// The commands come from the window's own DataContext, resolved when the menu
/// is opened rather than when the row is realised — a virtualized list builds
/// rows before it has a visual root to ask.
/// </remarks>
public static class TrackMenu
{
    /// <summary>
    /// The track this row is about. Setting it puts the menu on the control;
    /// setting it to null takes the menu off again.
    /// </summary>
    public static readonly AttachedProperty<Track?> TrackProperty =
        AvaloniaProperty.RegisterAttached<Control, Track?>("Track", typeof(TrackMenu));

    public static void SetTrack(Control control, Track? value) =>
        control.SetValue(TrackProperty, value);

    public static Track? GetTrack(Control control) => control.GetValue(TrackProperty);

    static TrackMenu()
    {
        OpensMenuProperty.Changed.AddClassHandler<Button>((button, args) =>
        {
            if (GetOpensMenu(button)) button.Click += (_, _) => OpenRowMenu(button);
        });

        TrackProperty.Changed.AddClassHandler<Control>((control, args) =>
        {
            if (GetTrack(control) is null)
            {
                control.ContextFlyout = null;
                return;
            }

            // Built once per control and then left alone: the row is recycled
            // with a different track, and the menu reads the track at the
            // moment it is opened rather than the one it was created with.
            control.ContextFlyout ??= Build(control);
        });
    }

    /// <summary>A themed resource by key, or null if the dictionary has no such entry.</summary>
    private static T? Resource<T>(string key) where T : class =>
        Application.Current?.TryFindResource(key, out var value) == true ? value as T : null;

    private static MenuFlyout Build(Control owner)
    {
        var flyout = new MenuFlyout();
        // Whichever of the two this server actually keeps leads the menu. It is
        // the action people reach for most and the only one that says something
        // about the song rather than about what to do with it next.
        var like = Item(owner, "Like", c => c.ToggleFavoriteCommand, "IconHeartOutline");
        var strip = new RatingStrip
        {
            FilledBrush = Resource<IBrush>("TextPrimary"),
            EmptyBrush = Resource<IBrush>("TextTertiary"),
        };
        var rate = RatingItem(owner, strip);
        // Decided when the menu opens, not when the row was built: a row is
        // recycled under a different song, the same song is liked and unliked
        // without the row changing, and the server can be swapped underneath
        // the whole list.
        flyout.Opening += (_, _) =>
        {
            var commands = Commands(owner);
            var ratings = commands?.UsesRatings == true;
            like.IsVisible = !ratings;
            rate.IsVisible = ratings;
            like.Header = GetTrack(owner)?.IsFavorite == true ? "Unlike" : "Like";
            MarkRating(strip, rate, GetTrack(owner)?.Rating);
        };
        flyout.ItemsSource = new object[]
        {
            like,
            rate,
            new Separator(),
            Item(owner, "Play Next", c => c.PlayTrackNextCommand, "IconPlayNext"),
            Item(owner, "Add to Queue", c => c.AddTrackToQueueCommand, "IconQueue"),
            Item(owner, "Start Radio", c => c.StartTrackRadioCommand, "IconWaveform"),
            new Separator(),
            Item(owner, "Go to Artist", c => c.OpenTrackArtistCommand, "IconArtist"),
            Item(owner, "Go to Album", c => c.OpenTrackAlbumCommand, "IconDisc"),
            new Separator(),
            Item(owner, "Download", c => c.DownloadTrackCommand, "IconDownload"),
            new Separator(),
            Item(owner, "Don't recommend this track", c => c.SuppressTrackCommand, "IconCircleX"),
            Item(owner, "Don't recommend this artist", c => c.SuppressTrackArtistCommand, "IconCircleX"),
        };
        return flyout;
    }

    /// <summary>
    /// The rating strip, at the top of the menu, for a server that keeps ratings.
    /// </summary>
    /// <remarks>
    /// It was a submenu listing "½", "★", "★½" … eleven entries you had to open
    /// a second menu to reach and then read as text. A rating is a value, not a
    /// command, and the phone has always shown it as one: five stars you click
    /// or drag across. So does this, in place, without the menu having to
    /// disappear and come back.
    ///
    /// The strip does not dismiss the menu either. A rating is usually adjusted
    /// twice — half a step either way — and a control that closes after one
    /// touch makes the second adjustment cost a whole reopen.
    /// </remarks>
    private static MenuItem RatingItem(Control owner, RatingStrip strip)
    {
        strip.Committed += (_, stars) => Rate(owner, stars);

        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 10,
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(strip);
        var readout = new TextBlock
        {
            VerticalAlignment = VerticalAlignment.Center,
            FontSize = 12,
            Foreground = Resource<IBrush>("TextTertiary"),
            // A FIXED width, not an automatic one, and this is load-bearing.
            //
            // The rating row is the widest thing in this menu, and the readout's
            // text changes with every half step — "No rating", "0.5 stars",
            // "1 star". Letting it size itself made the whole flyout re-measure
            // as the pointer crossed the strip, which moved the strip out from
            // under the pointer, which picked a different star, which changed
            // the text again: the menu shook and the rating flickered.
            //
            // Wide enough for the longest string it can hold, and clipped so an
            // unexpectedly long one cannot start the loop again.
            Width = ReadoutWidth,
            ClipToBounds = true,
        };
        row.Children.Add(readout);
        // The words follow the stars. Left on the committed value they said
        // "0 stars" under a strip previewing four, which is the control
        // disagreeing with itself.
        strip.Previewed += (_, stars) => readout.Text = Readout(stars);

        // StaysOpenOnClick so a half star does not dismiss the menu. The strip
        // also marks its own pointer events handled, which is what stops the
        // item counting the same press as a click on itself.
        var item = new MenuItem { Header = row, StaysOpenOnClick = true };
        // Not a command, so it must not wear a command's hover plate. Without
        // this the strip sat on a selection highlight that said "click me to do
        // the thing" about a row whose whole job is to be aimed at.
        item.Classes.Add("ratingRow");
        return item;
    }

    /// <summary>Show the rating the track already carries, in words beside the stars.</summary>
    private static void MarkRating(RatingStrip strip, MenuItem item, double? current)
    {
        strip.Value = current;
        if (item.Header is not StackPanel row) return;
        foreach (var child in row.Children.OfType<TextBlock>()) child.Text = Readout(current);
    }

    /// <summary>
    /// Room for "No rating" and for "0.5 stars", whichever is wider, at the
    /// readout's 12px size — with enough slack that no value it can produce
    /// makes it grow.
    /// </summary>
    private const double ReadoutWidth = 76;

    private static string Readout(double? value) =>
        value is { } stars ? RatingMath.Label(stars) : "No rating";

    private static void Rate(Control owner, double? stars)
    {
        if (Commands(owner) is not { } commands || GetTrack(owner) is not { } track) return;
        var parameter = new TrackRating(track, stars);
        if (commands.RateTrackCommand.CanExecute(parameter)) commands.RateTrackCommand.Execute(parameter);
    }

    /// <summary>
    /// Looks a Tabler geometry up by the key Icons.axaml files it under.
    ///
    /// Null when the key is missing, which leaves the item without an icon
    /// rather than without a menu — a missing glyph should not cost somebody
    /// the action next to it.
    /// </summary>
    private static Control? Glyph(string key)
    {
        if (Application.Current?.TryFindResource(key, out var found) != true) return null;
        if (found is not Geometry geometry) return null;
        // The brush has to be given: TablerIcon paints nothing without one, and
        // it does not inherit the menu's foreground. DynamicResource so the icon
        // follows a theme change rather than freezing at whichever theme was
        // loaded when the row was built.
        var brush = Application.Current?.TryFindResource("TextSecondary", out var brushValue) == true
            ? brushValue as IBrush
            : null;
        return new TablerIcon { Data = geometry, Size = 16, Brush = brush };
    }

    private static MenuItem Item(
        Control owner,
        string header,
        Func<ITrackMenuCommands, ICommand> pick,
        string? icon = null)
    {
        var item = new MenuItem { Header = header, Icon = icon is null ? null : Glyph(icon) };
        item.Click += (_, _) =>
        {
            if (Commands(owner) is not { } commands) return;
            var track = GetTrack(owner);
            if (track is null) return;
            var command = pick(commands);
            if (command.CanExecute(track)) command.Execute(track);
        };
        return item;
    }

    /// <summary>
    /// Marks a button as the row's overflow control.
    /// </summary>
    /// <remarks>
    /// Right-click was the only way to reach any of this, which is a poor way
    /// to publish a feature: somebody who does not already know the menu exists
    /// has no reason to try. A visible control on the row says so.
    /// </remarks>
    public static readonly AttachedProperty<bool> OpensMenuProperty =
        AvaloniaProperty.RegisterAttached<Button, bool>("OpensMenu", typeof(TrackMenu));

    public static void SetOpensMenu(Button button, bool value) =>
        button.SetValue(OpensMenuProperty, value);

    public static bool GetOpensMenu(Button button) => button.GetValue(OpensMenuProperty);

    /// <summary>
    /// Opens the menu belonging to the row this button sits in.
    ///
    /// The flyout is the row's, not the button's: one menu per row, reached
    /// either way, so the two routes can never drift into different menus.
    /// </summary>
    private static void OpenRowMenu(Button button)
    {
        for (Visual? v = button; v is not null; v = v.GetVisualParent())
        {
            if (v is Control control && GetTrack(control) is not null
                && control.ContextFlyout is { } flyout)
            {
                flyout.ShowAt(button);
                return;
            }
        }
    }

    /// <summary>
    /// The window's view model, or null before the row has a visual root — which
    /// is the ordinary state of a virtualized row that has not been shown yet.
    /// </summary>
    private static ITrackMenuCommands? Commands(Control owner) =>
        TopLevel.GetTopLevel(owner)?.DataContext as ITrackMenuCommands;
}
