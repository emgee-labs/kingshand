BeforeAll {
    $script:Renderer = "$PSScriptRoot\..\bin\Render-Review.ps1"
    $script:Out = Join-Path $TestDrive 'review.html'

    $script:Sections = @(
        @{ heading = 'Requirements'; items = @(
            @{ id='R-001'; text='Archived patients excluded'; detail='General Rules bullet 3'; badges=@('explicit'); flag=$false },
            @{ id='R-002'; text='Start Recording never greyed out'; detail='AC bullet 7'; badges=@('edge-case'); flag=$true }
        )},
        @{ heading = 'Files'; items = @(
            @{ id='F-001'; text='src/search.ts'; detail='+12 -3'; badges=@(); flag=$false }
        )}
    )

    & $script:Renderer -Title 'Ticket T-1001' -Subtitle 'ready to land' -Sections $script:Sections -OutputPath $script:Out
    $script:Html = Get-Content $script:Out -Raw
}

Describe 'Render-Review' {
    It 'writes an output file' { Test-Path $script:Out | Should -BeTrue }

    It 'produces a complete HTML document' {
        $script:Html | Should -Match '(?i)<!doctype html>'
        $script:Html | Should -Match '(?i)</html>'
    }

    It 'renders the title and subtitle' {
        $script:Html | Should -Match 'Ticket T-1001'
        $script:Html | Should -Match 'ready to land'
    }

    It 'renders every section heading' {
        $script:Html | Should -Match 'Requirements'
        $script:Html | Should -Match 'Files'
    }

    It 'anchors every item for lavish' {
        foreach ($id in @('R-001','R-002','F-001')) {
            $script:Html | Should -Match "data-item-id=`"$id`""
        }
    }

    It 'marks a flagged item' {
        $script:Html | Should -Match '(?s)data-item-id="R-002".*?flagged'
    }

    It 'does not mark an unflagged item' {
        $m = [regex]::Match($script:Html, '(?s)data-item-id="R-001".*?</article>').Value
        $m | Should -Not -Match 'flagged'
    }

    It 'inlines the stylesheet rather than linking it' {
        $script:Html | Should -Match '(?i)<style>'
        $script:Html | Should -Not -Match '(?i)<link[^>]*stylesheet'
    }

    It 'escapes HTML in item text' {
        $p = Join-Path $TestDrive 'x.html'
        & $script:Renderer -Title 'T' -Subtitle 'S' -OutputPath $p -Sections @(
            @{ heading='H'; items=@( @{ id='I1'; text='<script>alert(1)</script>'; detail=''; badges=@(); flag=$false } ) })
        $h = Get-Content $p -Raw
        $h | Should -Not -Match '<script>alert\(1\)</script>'
        $h | Should -Match '&lt;script&gt;'
    }

    It 'uses no long dashes anywhere in the output' {
        $script:Html | Should -Not -Match ([char]0x2014)
    }

    It 'handles an empty section list without throwing' {
        $p = Join-Path $TestDrive 'empty.html'
        { & $script:Renderer -Title 'T' -Subtitle 'S' -Sections @() -OutputPath $p } | Should -Not -Throw
        Test-Path $p | Should -BeTrue
    }
}
