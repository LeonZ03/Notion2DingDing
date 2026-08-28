[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DocxPath,
    [int]$LandscapeContentWidthDxa = 14400
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$wordNamespace = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
$resolvedDocx = [IO.Path]::GetFullPath($DocxPath)
if (-not (Test-Path -LiteralPath $resolvedDocx -PathType Leaf)) {
    throw "DOCX 不存在：$resolvedDocx"
}

function Get-OrCreateWordChild {
    param(
        [Parameter(Mandatory)][Xml.XmlDocument]$Document,
        [Parameter(Mandatory)][Xml.XmlElement]$Parent,
        [Parameter(Mandatory)][Xml.XmlNamespaceManager]$Namespaces,
        [Parameter(Mandatory)][string]$Name,
        [switch]$InsertFirst
    )
    $existing = $Parent.SelectSingleNode("./w:$Name", $Namespaces)
    if ($existing) { return $existing }
    $created = $Document.CreateElement('w', $Name, $script:wordNamespace)
    if ($InsertFirst -and $Parent.FirstChild) {
        [void]$Parent.InsertBefore($created, $Parent.FirstChild)
    }
    else {
        [void]$Parent.AppendChild($created)
    }
    return $created
}

function Set-WordAttribute {
    param(
        [Parameter(Mandatory)][Xml.XmlElement]$Element,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    [void]$Element.SetAttribute($Name, $script:wordNamespace, $Value)
}

function Resize-WordTable {
    param(
        [Parameter(Mandatory)][Xml.XmlDocument]$Document,
        [Parameter(Mandatory)][Xml.XmlElement]$Table,
        [Parameter(Mandatory)][Xml.XmlNamespaceManager]$Namespaces,
        [Parameter(Mandatory)][int]$TargetWidthDxa
    )
    $tableProperties = Get-OrCreateWordChild -Document $Document -Parent $Table -Namespaces $Namespaces -Name 'tblPr' -InsertFirst
    $tableWidth = Get-OrCreateWordChild -Document $Document -Parent $tableProperties -Namespaces $Namespaces -Name 'tblW'
    Set-WordAttribute -Element $tableWidth -Name 'type' -Value 'dxa'
    Set-WordAttribute -Element $tableWidth -Name 'w' -Value ([string]$TargetWidthDxa)

    $layout = Get-OrCreateWordChild -Document $Document -Parent $tableProperties -Namespaces $Namespaces -Name 'tblLayout'
    Set-WordAttribute -Element $layout -Name 'type' -Value 'fixed'

    $gridColumns = @($Table.SelectNodes('./w:tblGrid/w:gridCol', $Namespaces))
    if ($gridColumns.Count -eq 0) { return @() }

    $oldWidths = [Collections.Generic.List[int]]::new()
    $oldTotal = 0
    foreach ($column in $gridColumns) {
        $raw = $column.GetAttribute('w', $script:wordNamespace)
        $parsed = 0
        if (-not [int]::TryParse($raw, [ref]$parsed) -or $parsed -le 0) { $parsed = 1 }
        $oldWidths.Add($parsed)
        $oldTotal += $parsed
    }

    $newWidths = [Collections.Generic.List[int]]::new()
    $assigned = 0
    for ($index = 0; $index -lt $gridColumns.Count; $index += 1) {
        $newWidth = if ($index -eq $gridColumns.Count - 1) {
            $TargetWidthDxa - $assigned
        }
        else {
            [Math]::Max(1, [int][Math]::Round($TargetWidthDxa * $oldWidths[$index] / $oldTotal))
        }
        $newWidths.Add($newWidth)
        $assigned += $newWidth
        Set-WordAttribute -Element $gridColumns[$index] -Name 'w' -Value ([string]$newWidth)
    }

    foreach ($row in @($Table.SelectNodes('./w:tr', $Namespaces))) {
        $position = 0
        foreach ($cell in @($row.SelectNodes('./w:tc', $Namespaces))) {
            $cellProperties = Get-OrCreateWordChild -Document $Document -Parent $cell -Namespaces $Namespaces -Name 'tcPr' -InsertFirst
            $spanNode = $cellProperties.SelectSingleNode('./w:gridSpan', $Namespaces)
            $span = 1
            if ($spanNode) {
                $candidate = 0
                if ([int]::TryParse($spanNode.GetAttribute('val', $script:wordNamespace), [ref]$candidate) -and $candidate -gt 0) {
                    $span = $candidate
                }
            }
            $cellWidth = 0
            for ($offset = 0; $offset -lt $span -and ($position + $offset) -lt $newWidths.Count; $offset += 1) {
                $cellWidth += $newWidths[$position + $offset]
            }
            if ($cellWidth -le 0) { $cellWidth = [Math]::Max(1, [int]($TargetWidthDxa / $gridColumns.Count)) }
            $widthNode = Get-OrCreateWordChild -Document $Document -Parent $cellProperties -Namespaces $Namespaces -Name 'tcW'
            Set-WordAttribute -Element $widthNode -Name 'type' -Value 'dxa'
            Set-WordAttribute -Element $widthNode -Name 'w' -Value ([string]$cellWidth)
            $position += $span
        }
    }
    return @($newWidths)
}

function Set-BorderlessLayoutTable {
    param(
        [Parameter(Mandatory)][Xml.XmlDocument]$Document,
        [Parameter(Mandatory)][Xml.XmlElement]$Table,
        [Parameter(Mandatory)][Xml.XmlNamespaceManager]$Namespaces
    )
    $tableProperties = Get-OrCreateWordChild -Document $Document -Parent $Table -Namespaces $Namespaces -Name 'tblPr' -InsertFirst
    $existingBorders = $tableProperties.SelectSingleNode('./w:tblBorders', $Namespaces)
    if ($existingBorders) { [void]$tableProperties.RemoveChild($existingBorders) }
    $borders = $Document.CreateElement('w', 'tblBorders', $script:wordNamespace)
    foreach ($name in @('top', 'left', 'bottom', 'right', 'insideH', 'insideV')) {
        $border = $Document.CreateElement('w', $name, $script:wordNamespace)
        Set-WordAttribute -Element $border -Name 'val' -Value 'nil'
        Set-WordAttribute -Element $border -Name 'sz' -Value '0'
        [void]$borders.AppendChild($border)
    }
    [void]$tableProperties.AppendChild($borders)

    $existingMargins = $tableProperties.SelectSingleNode('./w:tblCellMar', $Namespaces)
    if ($existingMargins) { [void]$tableProperties.RemoveChild($existingMargins) }
    $margins = $Document.CreateElement('w', 'tblCellMar', $script:wordNamespace)
    foreach ($name in @('top', 'left', 'bottom', 'right')) {
        $margin = $Document.CreateElement('w', $name, $script:wordNamespace)
        Set-WordAttribute -Element $margin -Name 'w' -Value '60'
        Set-WordAttribute -Element $margin -Name 'type' -Value 'dxa'
        [void]$margins.AppendChild($margin)
    }
    [void]$tableProperties.AppendChild($margins)
}

$archive = [IO.Compression.ZipFile]::Open($resolvedDocx, [IO.Compression.ZipArchiveMode]::Update)
try {
    $entry = $archive.GetEntry('word/document.xml')
    if (-not $entry) { throw 'DOCX 缺少 word/document.xml。' }
    $stream = $entry.Open()
    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
    try { $xmlText = $reader.ReadToEnd() }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }

    $document = [Xml.XmlDocument]::new()
    $document.PreserveWhitespace = $true
    $document.LoadXml($xmlText)
    $namespaces = [Xml.XmlNamespaceManager]::new($document.NameTable)
    $namespaces.AddNamespace('w', $wordNamespace)

    $layoutTables = @($document.SelectNodes("//w:tbl[w:tblPr/w:tblStyle[@w:val='Notion Columns']]", $namespaces))
    $layoutColumnCount = 0
    foreach ($layoutTable in $layoutTables) {
        $columnWidths = @(Resize-WordTable -Document $document -Table $layoutTable -Namespaces $namespaces -TargetWidthDxa $LandscapeContentWidthDxa)
        Set-BorderlessLayoutTable -Document $document -Table $layoutTable -Namespaces $namespaces
        $cells = @($layoutTable.SelectNodes('./w:tr[1]/w:tc', $namespaces))
        if ($cells.Count -lt 2) {
            throw 'DOCX 布局表少于两列；单列内容必须直接输出，不能保留 1×1 布局表。'
        }
        $layoutColumnCount += $cells.Count
        for ($index = 0; $index -lt $cells.Count; $index += 1) {
            $cellWidth = if ($index -lt $columnWidths.Count) { $columnWidths[$index] } else { [int]($LandscapeContentWidthDxa / $cells.Count) }
            $nestedTarget = [Math]::Max(720, $cellWidth - 120)
            foreach ($candidate in @($cells[$index].SelectNodes('.//w:tbl', $namespaces))) {
                $ancestor = $candidate.ParentNode
                while ($ancestor -and $ancestor.LocalName -ne 'tbl') { $ancestor = $ancestor.ParentNode }
                if ([object]::ReferenceEquals($ancestor, $layoutTable)) {
                    [void](Resize-WordTable -Document $document -Table $candidate -Namespaces $namespaces -TargetWidthDxa $nestedTarget)
                }
            }
        }
    }

    $body = $document.SelectSingleNode('//w:body', $namespaces)
    if (-not $body) { throw 'DOCX 正文缺少 w:body。' }
    $tableSequence = [Collections.Generic.List[object]]::new()
    foreach ($table in @($document.SelectNodes('//w:tbl', $namespaces))) {
        $style = $table.SelectSingleNode('./w:tblPr/w:tblStyle', $namespaces)
        $styleValue = if ($style) { $style.GetAttribute('val', $wordNamespace) } else { '' }
        $cells = @($table.SelectNodes('./w:tr[1]/w:tc', $namespaces))
        if ($cells.Count -lt 1) { throw 'DOCX 表格缺少可核对的首行单元格。' }
        $tableSequence.Add([pscustomobject]@{
            kind = if ($styleValue -eq 'Notion Columns') { 'layout' } else { 'data' }
            columnCount = $cells.Count
        })
    }
    $section = $document.SelectSingleNode('(//w:sectPr)[last()]', $namespaces)
    if (-not $section) {
        $section = $document.CreateElement('w', 'sectPr', $wordNamespace)
        [void]$body.AppendChild($section)
    }
    $pageSize = Get-OrCreateWordChild -Document $document -Parent $section -Namespaces $namespaces -Name 'pgSz'
    $pageMargins = Get-OrCreateWordChild -Document $document -Parent $section -Namespaces $namespaces -Name 'pgMar'
    if ($layoutTables.Count -gt 0) {
        Set-WordAttribute -Element $pageSize -Name 'w' -Value '15840'
        Set-WordAttribute -Element $pageSize -Name 'h' -Value '12240'
        Set-WordAttribute -Element $pageSize -Name 'orient' -Value 'landscape'
        foreach ($name in @('left', 'right')) { Set-WordAttribute -Element $pageMargins -Name $name -Value '720' }
        foreach ($name in @('top', 'bottom')) { Set-WordAttribute -Element $pageMargins -Name $name -Value '720' }
    }
    else {
        Set-WordAttribute -Element $pageSize -Name 'w' -Value '12240'
        Set-WordAttribute -Element $pageSize -Name 'h' -Value '15840'
        foreach ($name in @('left', 'right', 'top', 'bottom')) { Set-WordAttribute -Element $pageMargins -Name $name -Value '1440' }
    }
    Set-WordAttribute -Element $pageMargins -Name 'header' -Value '720'
    Set-WordAttribute -Element $pageMargins -Name 'footer' -Value '720'
    Set-WordAttribute -Element $pageMargins -Name 'gutter' -Value '0'

    $memory = [IO.MemoryStream]::new()
    $settings = [Xml.XmlWriterSettings]::new()
    $settings.Encoding = New-Object Text.UTF8Encoding($false)
    $settings.Indent = $false
    $writer = [Xml.XmlWriter]::Create($memory, $settings)
    try { $document.Save($writer) }
    finally { $writer.Dispose() }
    $bytes = $memory.ToArray()
    $memory.Dispose()

    $entry.Delete()
    $replacement = $archive.CreateEntry('word/document.xml', [IO.Compression.CompressionLevel]::Optimal)
    $output = $replacement.Open()
    try { $output.Write($bytes, 0, $bytes.Length) }
    finally { $output.Dispose() }

    [pscustomobject]@{
        success = $true
        layoutTableCount = $layoutTables.Count
        layoutColumnCount = $layoutColumnCount
        tableSequence = @($tableSequence)
        pageOrientation = if ($layoutTables.Count -gt 0) { 'landscape' } else { 'portrait' }
        contentWidthDxa = if ($layoutTables.Count -gt 0) { $LandscapeContentWidthDxa } else { 9360 }
    } | ConvertTo-Json -Depth 5 -Compress
}
finally {
    $archive.Dispose()
}
