using Mozz.Desktop.ViewModels;
using Xunit;

namespace Mozz.Desktop.Tests;

/// <summary>
/// Chunking a flat listing into rows so a VirtualizingStackPanel can own it.
///
/// The interesting cases are all about the *partial last row*. Pages arrive in
/// fixed sizes that will not divide evenly by however many tiles fit across the
/// window, so almost every append lands mid-row. Getting that wrong leaves a
/// ragged hole in the middle of the grid, which looks like a rendering bug and
/// is not one.
/// </summary>
public class GridRowsTests
{
    private static GridRows<int> Grid(int columns)
    {
        var grid = new GridRows<int>();
        grid.SetColumns(columns);
        return grid;
    }

    private static void AssertShape(GridRows<int> grid, int total, int columns)
    {
        var flat = grid.Rows.SelectMany(r => r).ToList();
        Assert.Equal(total, flat.Count);
        Assert.Equal(Enumerable.Range(0, total), flat);

        var expectedRows = (int)Math.Ceiling(total / (double)columns);
        Assert.Equal(expectedRows, grid.Rows.Count);

        // Only the final row may be short — that is the whole invariant.
        foreach (var row in grid.Rows.Take(Math.Max(0, grid.Rows.Count - 1)))
        {
            Assert.Equal(columns, row.Count);
        }
        if (grid.Rows.Count > 0) Assert.InRange(grid.Rows[^1].Count, 1, columns);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(4)]
    [InlineData(7)]
    public void ResetChunksEvenly(int columns)
    {
        var grid = Grid(columns);
        grid.Reset(Enumerable.Range(0, 30));
        AssertShape(grid, 30, columns);
    }

    [Fact]
    public void EmptyResetProducesNoRows()
    {
        var grid = Grid(5);
        grid.Reset([]);
        Assert.Empty(grid.Rows);
        grid.Reset(null);
        Assert.Empty(grid.Rows);
    }

    /// A page size that does not divide by the column count — i.e. the normal
    /// case, since one is 200 and the other depends on window width.
    [Theory]
    [InlineData(5, 7)]
    [InlineData(7, 5)]
    [InlineData(3, 3)]
    [InlineData(1, 9)]
    public void AppendsFillThePartialRowBeforeStartingNewOnes(int columns, int pageSize)
    {
        var grid = Grid(columns);
        var next = 0;
        grid.Reset(Enumerable.Range(next, pageSize));
        next += pageSize;
        AssertShape(grid, next, columns);

        for (var page = 0; page < 6; page++)
        {
            grid.Append(Enumerable.Range(next, pageSize).ToList());
            next += pageSize;
            AssertShape(grid, next, columns);
        }
    }

    [Fact]
    public void AppendingNothingChangesNothing()
    {
        var grid = Grid(4);
        grid.Reset(Enumerable.Range(0, 10));
        var before = grid.Rows.Count;
        grid.Append([]);
        grid.Append(null);
        Assert.Equal(before, grid.Rows.Count);
        AssertShape(grid, 10, 4);
    }

    /// Resizing the window rechunks everything, and must not lose or reorder a
    /// single item.
    [Fact]
    public void ChangingColumnsRechunksWithoutLosingItems()
    {
        var grid = Grid(4);
        grid.Reset(Enumerable.Range(0, 50));
        grid.Append(Enumerable.Range(50, 23).ToList());
        AssertShape(grid, 73, 4);

        foreach (var columns in new[] { 7, 2, 11, 1, 6 })
        {
            grid.SetColumns(columns);
            AssertShape(grid, 73, columns);
        }
    }

    [Fact]
    public void ColumnsAreClampedToAtLeastOne()
    {
        var grid = new GridRows<int>();
        grid.SetColumns(0);
        Assert.Equal(1, grid.Columns);
        grid.SetColumns(-5);
        Assert.Equal(1, grid.Columns);
        grid.Reset(Enumerable.Range(0, 3));
        AssertShape(grid, 3, 1);
    }

    /// A layout pass fires far more often than the width really changes; an
    /// unchanged column count must not rebuild the rows, because rebuilding
    /// resets scroll position.
    [Fact]
    public void SettingTheSameColumnCountDoesNotRebuild()
    {
        var grid = Grid(5);
        grid.Reset(Enumerable.Range(0, 20));
        var firstRow = grid.Rows[0];
        grid.SetColumns(5);
        Assert.Same(firstRow, grid.Rows[0]);
    }

    [Fact]
    public void AppendAfterAnExactlyFullRowStartsANewRow()
    {
        var grid = Grid(4);
        grid.Reset(Enumerable.Range(0, 8));   // exactly two full rows
        Assert.Equal(2, grid.Rows.Count);
        grid.Append(Enumerable.Range(8, 2).ToList());
        Assert.Equal(3, grid.Rows.Count);
        AssertShape(grid, 10, 4);
    }
}
