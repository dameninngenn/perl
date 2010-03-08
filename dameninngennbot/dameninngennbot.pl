#!/usr/bin/perl

# マルコフ連鎖POST
# OAuth ver

use strict;
use Net::Twitter;
use LWP::Simple;
use XML::Simple;
use File::Basename;
use Cwd 'abs_path';
use Dumpvalue;

my $d = Dumpvalue->new();   # デバッグ用

# OAuth settings
use constant CONSUMER_KEY => 'CONSUMER_KEY';
use constant CONSUMER_KEY_SECRET => 'CONSUMER_KEY_SECRET';
use constant ACCESS_TOKEN => 'ACCESS_TOKEN';
use constant ACCESS_TOKEN_SECRET => 'ACCESS_TOKEN_SECRET';

# XML settings
use constant TWITTER_XML_URL => 'http://twitter.com/statuses/user_timeline/--USER_ID--.xml?count=100';
use constant OWNER_USER_ID => 'OWNER_USER_ID';
use constant APPID => 'APPID';
use constant API_BASE_URL => 'http://jlp.yahooapis.jp/MAService/V1/parse';
use constant API_FIX_PARAM => '&result=ma';

# other settings
use constant SINCE_ID_FILENAME => '.since_id';
use constant ROOP_COUNT => 50;
use constant RAND_PROB => 10;   # 確率の分子
use constant RAND_PARAM => 100; # 確率の分母

# OAuthの準備(global)
my $twitter = Net::Twitter->new(
  traits          => ['API::REST', 'OAuth'],
  consumer_key    => CONSUMER_KEY,
  consumer_secret => CONSUMER_KEY_SECRET,
);
$twitter->access_token(ACCESS_TOKEN);
$twitter->access_token_secret(ACCESS_TOKEN_SECRET);

# main
{
    # 前回のmentionsの最大のIDをファイルから読み込み
    my $since_id = &read_since_id(SINCE_ID_FILENAME);

    # 新規mentionsに対してreplyを返す
    my $recent_since_id = &reaction_to_mentions($since_id);

    # 今回のmentionの最大のIDをファイルに書き込み
    &write_since_id(SINCE_ID_FILENAME,$recent_since_id);

    # 確率でPOSTする
    my @rand_val = 1 .. RAND_PARAM;
    if(rand @rand_val < RAND_PROB){
        my $owner_xml_url = TWITTER_XML_URL;
        my $owner_user_id = OWNER_USER_ID;
        $owner_xml_url =~ s/--USER_ID--/$owner_user_id/;

        # XMLを取得しマルコフ連鎖文字列を生成
        my $tweet_str = &make_markov_chain_str($owner_xml_url);

        # 返ってきた文字列がundefでなければPOSTする
        if(defined $tweet_str){
            my $res = $twitter->update({ status => "$tweet_str" }); 
        }
    }
}

# 新着mentionに対して相手のPOST履歴からマルコフ連鎖文字列を生成しreplyを返す
#
# ARGV:
#   $since_id : 前回のmentionsの最大のID
#
# return:
#   $recent_since_id : 今回のmentionの最大のID 
#
sub reaction_to_mentions{
    my $since_id = my $recent_since_id = shift;
    my %uniq_user;

    # mentions取得
    my $mentions = $twitter->mentions();

    foreach(@{$mentions}){
        my $user_xml_url = TWITTER_XML_URL;

        # 今回のmentionの最大のIDが$recent_since_idに入るようにする
        $recent_since_id = &max($recent_since_id,$_->{'id'});

        # 以下の条件に一致するものにはreplyしない
        #   ・前回のmentionsの最大のIDより前のIDのもの
        #   ・先頭以外に@があるもの
        #   ・プロテクトアカウント
        #   ・今回の起動で既に1回replyしたユーザー
        if($_->{'id'} <= $since_id or $_->{'text'} =~ m/^(.)(.*)\@/ or $_->{'user'}->{'protected'} == 1 or exists $uniq_user{$_->{'user'}->{'id'}}){
            next;
        }

        # $since_idが0だった場合今回のIDを入れておく
        unless($since_id){
            $since_id = $_->{'id'};
        }

        # 今回replyしたユーザーのリスト
        $uniq_user{$_->{'user'}->{'id'}} = 1;

        # 取得するXMLのURLにuser_idをセット
        $user_xml_url =~ s/--USER_ID--/$_->{'user'}->{'id'}/;

        # XMLを取得しマルコフ連鎖文字列を生成
        my $tweet_str = &make_markov_chain_str($user_xml_url);

        # 返ってきた文字列がundefでなければ@、in_reply_toをつけてPOSTする
        if(defined $tweet_str){
            $tweet_str = '@'.$_->{'user'}->{'screen_name'}.' '.$tweet_str;
            my $res = $twitter->update({ status => "$tweet_str", in_reply_to_status_id => $_->{'id'} }); 
        }
        sleep(10);
    }
    return $recent_since_id;
}

# 指定XMLからマルコフ連鎖文字列を生成
#
# ARGV:
#   $xml_url : 取得対象XMLのURL
#
# return:
#   undef or $tweet_str : 生成したマルコフ連鎖文字列
#
sub make_markov_chain_str{
    my $xml_url = shift;
    my $markov_table;
    my $tweet_list;
    my @head_word;

    # XML取得
    my $xml_result = get($xml_url);
    my $xs = new XML::Simple();
    my $ref = $xs->XMLin($xml_result);

    # textキーのみハッシュへ
    foreach my $key (sort keys %{$ref->{'status'}}){
        $tweet_list->{$key} = $ref->{'status'}->{$key}->{'text'};
    }

    # 1POSTごとに形態素解析しマルコフテーブルを作成
    foreach my $key (keys %{$tweet_list}){
        my @markov_list;

        # # @ http を含むPOSTの場合はスキップ
        if($tweet_list->{$key} =~ m/http/ or $tweet_list->{$key} =~ m/\@/ or $tweet_list->{$key} =~ m/＠/ or $tweet_list->{$key} =~ m/\#/ or $tweet_list->{$key} =~ m/＃/){
            next;
        }

        # apiを叩いて形態素解析
        my $api_param = '?appid='.APPID.'&sentence='.$tweet_list->{$key}.API_FIX_PARAM;
        my $api_url = API_BASE_URL.$api_param;
        my $api_res = get($api_url);
        chomp($api_res); 

        # 切り出された単語をリストにpushする
        while($api_res =~ m/<surface>(.+?)<\/surface>/g){
            unless(scalar(@markov_list)){
                push (@head_word,$1);
            }
            push (@markov_list,$1);
        }

        # マルコフテーブルを作成
        foreach my $num (0 .. $#markov_list){
            push (@{ $markov_table->{$markov_list[$num]} },$markov_list[$num+1]);
        }
    }

    # 要素数が0の場合何もしない
    unless(scalar(keys(%{$markov_table}))){
        return;
    }

    # 最初の単語を決定
    my $tweet_str = my $chain_word = $head_word[rand @head_word];

    # 無限ループしないよう最大回数を決めてマルコフ連鎖
    foreach (0 .. ROOP_COUNT){
        my $add_word = $markov_table->{$chain_word}->[rand @{$markov_table->{$chain_word}}];
        $tweet_str .= $chain_word = $add_word;
    }
    return $tweet_str;
}

# IDをファイルに書き込み
#
# ARGV:
#   $filename : 書き込み対象ファイル名
#   $id : 書き込みID
#
# return:
#   undef
#
sub write_since_id{
    my $filename = shift;
    my $id = shift;
    my $since_id_file = dirname(abs_path($0)) . '/' . $filename;

    open (OUT, ">$since_id_file");
    print OUT $id;
    close(OUT);

    return;
}

# IDをファイルから読み込み
#
# ARGV:
#   $filename : 読み込み対象ファイル名
#
# return:
#   $id : ファイルから読み込んだID
#
sub read_since_id{
    my $filename = shift;
    my $since_id_file = dirname(abs_path($0)) . '/' . $filename;
    my $id = 0;

    if(open IN,$since_id_file){
        $id = <IN>;
        chomp($id);
    }
    close(IN);

    return $id;
}

# 最大値判定処理
#
# ARGV:
#   $val1 : 比較する値
#   $val2 : 比較する値
#
# return:
#   $val1 or $val2 : $val1と$val2を比較し大きい方の値を返す
#
sub max{
    my $val1 = shift;
    my $val2 = shift;

    if($val1 >= $val2){
        return $val1;
    }
    else{
        return $val2;
    }
}
